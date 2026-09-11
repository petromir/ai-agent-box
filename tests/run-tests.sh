#!/usr/bin/env bash
#
# Test suite for the ai-agent-box images.
#
# Automates the AGENTS.md "Verify every change" checklist:
#
#   opencode image (ai-agent-box:local)
#     - build
#     - bundled shellcheck: pinned version runs, flags a known issue, passes a
#       clean script, and its GPLv3 license text + source pointer ship in the
#       image (repeated for the omp and java images)
#     - default (non-root) path: --version prints the release
#     - root/uid-adaptation path (legacy --user 0): "adapting uid/gid..."
#       message, adapted user can git-status /workspace and write
#       ~/.config/opencode and ~/.local/share/opencode
#     - serve path: health endpoint reachable through the published port and
#       reports the installed version; an explicit --hostname override binds
#       loopback only (unreachable from the host)
#     - hardening (README "Hardening: keeping the agent scoped to
#       /workspace"): default path works with --cap-drop=ALL,
#       --security-opt=no-new-privileges, and --read-only + tmpfs; the
#       --user 0 path works with the documented minimal capability set
#       (CHOWN, SETUID, SETGID, SETPCAP) plus no-new-privileges
#     - arbitrary-uid path (PLAN-arbitrary-uid-home-layout.md): the zero-
#       `--user` default stays uid=10001 gid=10001 (unchanged); an arbitrary
#       uid with gid 0 (primary or via --group-add) can write the home tree
#       and use git with NO uid/gid rewrite and NO root at any point; the
#       same uid without gid 0 in any form cannot write (negative control);
#       the recipe works with --cap-drop=ALL + --read-only (--user 0 cannot);
#       ssh/whoami resolve the uid via the entrypoint's passwd self-heal
#   omp image (ai-agent-box:omp-local)
#     - build
#     - bundled shellcheck: same checks as the opencode image
#     - default (non-root) path: --version prints omp/<release>
#     - root/uid-adaptation path (legacy --user 0): same as above for
#       ~/.omp and ~/.omp/agent
#     - mount safety: the entrypoint never creates or chowns anything inside a
#       bind-mounted ~/.omp or ~/.omp/agent, and a non-root run with a mounted
#       ~/.omp does not abort
#     - hardening: same checks as the opencode image
#     - arbitrary-uid path: same checks as the opencode image, for
#       ~/.omp and ~/.omp/agent
#   java image (ai-agent-box:java, derived from ai-agent-box:local)
#     - build with BASE_IMAGE=ai-agent-box:local
#     - default path: opencode --version plus java/mvnd/python3 toolchain
#     - bundled shellcheck: same checks as the opencode image (inherited)
#     - uid-adaptation path (legacy --user 0)
#     - serve path (health + hostname override)
#     - hardening: same checks as the opencode image (the arbitrary-uid path
#       is not re-tested here — it lives entirely in the inherited base-image
#       entrypoint/Dockerfile layout, already covered by the opencode checks)
#
# Docker Desktop (macOS) squashes bind-mount ownership, so the native-Linux
# foreign-uid case is simulated deterministically: a derived "sim" image chowns
# /workspace (a real git repo) to uid 999 in an image layer, and a fake agent
# binary is bind-mounted over the real one so the suite can observe the
# post-adaptation identity and directory writability.
#
# Usage:
#   tests/run-tests.sh                build all images and run every check
#   tests/run-tests.sh --skip-build   reuse already-built images
#   tests/run-tests.sh --only omp     subset: opencode, omp, java
#   tests/run-tests.sh --keep         keep temp dir and sim images for debugging
#
# Exit codes: 0 all checks passed, 1 at least one check failed, 2 setup error.

set -uo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)

oc_image=ai-agent-box:local
omp_image=ai-agent-box:omp-local
java_image=ai-agent-box:java

# Unusual ports so the suite does not clash with a locally running server.
oc_serve_port=14096
oc_override_port=14097
java_serve_port=14098
java_override_port=14099

# Must match ARG SHELLCHECK_VERSION in both Dockerfiles (v0.11.0 -> 0.11.0).
# The upstream tool ships no Wolfi package, so its pin lives in the Dockerfile.
shellcheck_version=0.11.0

run_id=$$
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/ai-agent-box-tests.XXXXXX")

skip_build=0
keep=0
only=""

pass=0
fail=0
containers=""
sim_images=""

oc_ver=""
omp_ver=""
java_ver=""

usage() {
    cat <<'EOF'
Usage: tests/run-tests.sh [--skip-build] [--keep] [--only opencode,omp,java]

  --skip-build  reuse already-built images instead of rebuilding them
  --keep        keep the temp dir and sim images for debugging
  --only LIST   comma-separated subset of variants: opencode, omp, java
EOF
}

ok()  { pass=$((pass + 1)); printf 'PASS  %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL  %s\n      %s\n' "$1" "$2"; }
die() { printf 'ERROR %s\n' "$1" >&2; exit 2; }

want() {
    [ -z "$only" ] && return 0
    case " $only " in *" $1 "*) return 0 ;; esac
    return 1
}

track() { containers="$containers $1"; }

have_image() { docker image inspect "$1" >/dev/null 2>&1; }

# assert_contains <test-name> <haystack> <needle>
assert_contains() {
    case "$2" in
        *"$3"*) ok "$1" ;;
        *) bad "$1" "expected to find '$3' in: $(printf '%s' "$2" | head -c 400)" ;;
    esac
}

# assert_not_contains <test-name> <haystack> <needle>
assert_not_contains() {
    case "$2" in
        *"$3"*) bad "$1" "expected NOT to find '$3' in: $(printf '%s' "$2" | head -c 400)" ;;
        *) ok "$1" ;;
    esac
}

assert_exit0() { # <test-name> <rc> <output>
    if [ "$2" -eq 0 ]; then
        ok "$1"
    else
        bad "$1" "exit code $2; output: $(printf '%s' "$3" | head -c 400)"
    fi
}

cleanup() {
    local c s
    for c in $containers; do
        docker rm -f "$c" >/dev/null 2>&1
    done
    if [ "$keep" -eq 0 ]; then
        for s in $sim_images; do docker rmi "$s" >/dev/null 2>&1; done
        rm -rf "$work_dir"
    else
        printf '\nkept temp dir: %s\nkept sim images:%s\n' "$work_dir" "$sim_images"
    fi
}
trap cleanup EXIT

# --- fixtures ---------------------------------------------------------------

write_fixtures() {
    # Runs in place of /usr/local/bin/opencode after the entrypoint has
    # adapted uid/gid and dropped privileges; reports the identity it runs as
    # and whether the state dirs are writable.
    cat > "$work_dir/fake-write-opencode.sh" <<'EOF'
#!/bin/sh
echo "probe uid=$(id -u) gid=$(id -g)"
if git -C /workspace status --short >/dev/null 2>&1; then echo "git-status OK"; else echo "git-status FAIL"; fi
if touch "$HOME/.config/opencode/.probe" 2>/dev/null; then echo "write-config OK"; else echo "write-config FAIL"; fi
if touch "$HOME/.local/share/opencode/.probe" 2>/dev/null; then echo "write-data OK"; else echo "write-data FAIL"; fi
EOF

    # Same probe for the omp image (~/.omp and ~/.omp/agent).
    cat > "$work_dir/fake-write-omp.sh" <<'EOF'
#!/bin/sh
echo "probe uid=$(id -u) gid=$(id -g)"
if git -C /workspace status --short >/dev/null 2>&1; then echo "git-status OK"; else echo "git-status FAIL"; fi
if touch "$HOME/.omp/.probe" 2>/dev/null; then echo "write-home OK"; else echo "write-home FAIL"; fi
if touch "$HOME/.omp/agent/.probe" 2>/dev/null; then echo "write-agent OK"; else echo "write-agent FAIL"; fi
EOF

    # Identity probe that writes nothing (used with bind-mounted state dirs,
    # so the suite can assert the entrypoint left the mount untouched).
    cat > "$work_dir/fake-readonly.sh" <<'EOF'
#!/bin/sh
echo "probe uid=$(id -u) gid=$(id -g)"
EOF

    # Identity + ssh probe, used to assert the arbitrary-uid passwd self-heal
    # (ensure_passwd_entry): whoami/ssh must resolve the running uid even
    # when it has no built-in passwd entry.
    cat > "$work_dir/fake-identity.sh" <<'EOF'
#!/bin/sh
echo "probe uid=$(id -u) gid=$(id -g)"
echo "whoami=$(whoami 2>&1)"
echo "ssh=$(ssh -V 2>&1)"
EOF

    # Fixtures for the bundled linter: the first must produce SC2086, the
    # second nothing.
    cat > "$work_dir/shellcheck-bad.sh" <<'EOF'
#!/bin/sh
echo $1
EOF
    cat > "$work_dir/shellcheck-clean.sh" <<'EOF'
#!/bin/sh
echo "ok"
EOF

    chmod +x "$work_dir"/fake-*.sh
}

# make_sim <base-image> <sim-tag>
# Derives an image whose /workspace is a git repo owned by foreign uid 999 —
# the deterministic stand-in for a native-Linux bind mount with host ownership.
make_sim() {
    cat > "$work_dir/sim.Dockerfile" <<EOF
FROM $1
USER root
RUN chown root:root /workspace \\
 && git init -q /workspace \\
 && git -C /workspace -c user.email=t@t -c user.name=t commit -q --allow-empty -m init \\
 && chown -R 999:999 /workspace
EOF
    if docker build -q -f "$work_dir/sim.Dockerfile" -t "$2" "$work_dir" >/dev/null 2>&1; then
        sim_images="$sim_images $2"
        return 0
    fi
    return 1
}

# --- build ------------------------------------------------------------------

# build_image <label> <dockerfile> <tag> [extra docker build args...]
build_image() {
    local label=$1 dockerfile=$2 tag=$3 logf
    shift 3
    logf="$work_dir/build-$label.log"
    if docker build -f "$repo_root/$dockerfile" "$@" -t "$tag" "$repo_root" >"$logf" 2>&1; then
        ok "$label: build"
        return 0
    fi
    bad "$label: build" "docker build failed; full log: $logf"
    return 1
}

# --- shared checks ----------------------------------------------------------

test_entrypoint_syntax() {
    if bash -n "$repo_root/opencode/opencode-entrypoint.sh" \
        && bash -n "$repo_root/omp/omp-entrypoint.sh"; then
        ok "entrypoints: bash -n syntax"
    else
        bad "entrypoints: bash -n syntax" "syntax error in an entrypoint script"
    fi
}

# run_adaptation <sim-image> <fake-script> <binary-path>
# Prints combined stdout+stderr; container exit code in $?.
run_adaptation() {
    docker run --rm --user 0 -v "$2:$3:ro" "$1" --version 2>&1
}

# wait_health <url> — prints the body once the endpoint answers (<=30s).
wait_health() {
    local body
    for _ in $(seq 1 30); do
        body=$(curl -s --max-time 2 "$1" 2>/dev/null)
        if [ -n "$body" ]; then
            printf '%s' "$body"
            return 0
        fi
        sleep 1
    done
    return 1
}

# test_serve <image> <label> <host-port> <expected-version>
test_serve() {
    local image=$1 label=$2 port=$3 ver=$4 name health
    name="serve-$label-$run_id"
    if ! docker run --rm -d -p "$port:4096" --name "$name" "$image" serve >/dev/null 2>&1; then
        bad "$label: serve start" "docker run failed"
        return
    fi
    track "$name"
    if health=$(wait_health "http://localhost:$port/global/health"); then
        assert_contains "$label: serve health" "$health" '"healthy":true'
        if [ -n "$ver" ]; then
            assert_contains "$label: serve reports installed version" "$health" "\"version\":\"$ver\""
        fi
    else
        bad "$label: serve health" "no response on http://localhost:$port/global/health within 30s"
    fi
    docker rm -f "$name" >/dev/null 2>&1
}

# test_serve_override <image> <label> <port>
# An explicit --hostname 127.0.0.1 must win over the entrypoint's injected
# --hostname 0.0.0.0: reachable on loopback inside the container, unreachable
# from the host through the published port.
test_serve_override() {
    local image=$1 label=$2 port=$3 name inside host_out
    name="lb-$label-$run_id"
    if ! docker run --rm -d -p "$port:$port" --name "$name" "$image" \
        serve --port "$port" --hostname 127.0.0.1 >/dev/null 2>&1; then
        bad "$label: override start" "docker run failed"
        return
    fi
    track "$name"
    inside=""
    for _ in $(seq 1 30); do
        inside=$(docker exec "$name" curl -s --max-time 2 "http://127.0.0.1:$port/global/health" 2>/dev/null)
        [ -n "$inside" ] && break
        sleep 1
    done
    if [ -z "$inside" ]; then
        bad "$label: override binds loopback" "server never responded inside the container"
    else
        ok "$label: override binds loopback (reachable inside)"
        host_out=$(curl -s --max-time 3 "http://localhost:$port/global/health" 2>/dev/null)
        if [ -z "$host_out" ]; then
            ok "$label: override unreachable from host"
        else
            bad "$label: override unreachable from host" "got: $host_out"
        fi
    fi
    docker rm -f "$name" >/dev/null 2>&1
}

# --- bundled tooling: shellcheck --------------------------------------------

# test_shellcheck <image> <label>
# The bundled linter is installed as a pinned, checksum-verified upstream static
# binary (no Wolfi package exists). Checks that it runs at the pinned version,
# a known finding with a non-zero exit, passes a clean script, and that its
# GPLv3 license text and Corresponding-Source pointer are present in the image:
# those obligations attach as soon as the image is distributed.
test_shellcheck() {
    local image=$1 label=$2 out rc
    out=$(docker run --rm --entrypoint shellcheck "$image" --version 2>&1); rc=$?
    assert_exit0 "$label: shellcheck runs" "$rc" "$out"
    assert_contains "$label: shellcheck version matches pin" "$out" "version: $shellcheck_version"
    out=$(docker run --rm --entrypoint shellcheck \
        -v "$work_dir/shellcheck-bad.sh:/sc-bad.sh:ro" "$image" /sc-bad.sh 2>&1); rc=$?
    assert_contains "$label: shellcheck flags SC2086" "$out" "SC2086"
    if [ "$rc" -eq 0 ]; then
        bad "$label: shellcheck exits non-zero on findings" "exit 0; output: $(printf '%s' "$out" | head -c 200)"
    else
        ok "$label: shellcheck exits non-zero on findings"
    fi
    out=$(docker run --rm --entrypoint shellcheck \
        -v "$work_dir/shellcheck-clean.sh:/sc-clean.sh:ro" "$image" /sc-clean.sh 2>&1); rc=$?
    assert_exit0 "$label: shellcheck passes a clean script" "$rc" "$out"
    out=$(docker run --rm --entrypoint sh "$image" \
        -c 'cat /usr/share/doc/shellcheck/LICENSE.txt' 2>&1)
    assert_contains "$label: shellcheck GPL license text ships" "$out" "GNU GENERAL PUBLIC LICENSE"
    out=$(docker run --rm --entrypoint sh "$image" \
        -c 'cat /usr/share/doc/shellcheck/SOURCE.txt' 2>&1)
    assert_contains "$label: shellcheck source pointer ships" "$out" "refs/tags/v$shellcheck_version.tar.gz"
}

# --- hardening (README "Hardening: keeping the agent scoped to /workspace") -

# test_hardened_default <image> <label>
# Default non-root path with the README's recommended flags: all capabilities
# dropped, no-new-privileges, and a read-only root filesystem backed by
# tmpfs for /tmp and $HOME.
test_hardened_default() {
    local image=$1 label=$2 out rc
    out=$(docker run --rm \
        --cap-drop=ALL --security-opt=no-new-privileges \
        --read-only --tmpfs /tmp:rw,nosuid,nodev \
        --tmpfs /home/ai-agent-box:rw,nosuid,nodev,uid=10001,gid=10001 \
        -v "$repo_root:/workspace:ro" \
        "$image" --version 2>&1); rc=$?
    assert_exit0 "$label: hardened default (cap-drop=ALL, read-only, no-new-privileges)" "$rc" "$out"
}

# test_hardened_adaptation <sim-image> <fake-script> <binary-path> <label>
# --user 0 uid-adaptation path with the minimal capability set the README
# documents: CHOWN (entrypoint chowns), SETUID+SETGID (setpriv's identity
# switch), SETPCAP (setpriv's own --bounding-set -all hardening step, which
# clears the bounding set on the *target* process and needs CAP_SETPCAP to do
# so even though the target ends up with none of these capabilities).
test_hardened_adaptation() {
    local sim=$1 fake=$2 bin=$3 label=$4 out rc
    out=$(docker run --rm --user 0 \
        --cap-drop=ALL --cap-add=CHOWN --cap-add=SETUID --cap-add=SETGID --cap-add=SETPCAP \
        --security-opt=no-new-privileges \
        -v "$fake:$bin:ro" \
        "$sim" --version 2>&1); rc=$?
    assert_exit0 "$label: hardened adaptation (minimal caps, no-new-privileges)" "$rc" "$out"
    assert_contains "$label: hardened adaptation message" "$out" "adapting uid/gid to mounted workspace owner 999:999"
    assert_contains "$label: hardened adapted identity" "$out" "probe uid=999 gid=999"
}

# --- arbitrary-uid (PLAN-arbitrary-uid-home-layout.md) ----------------------
#
# These tests reuse the sim image already built by test_*_adaptation (its
# /workspace is chowned to uid 999 — the same deterministic stand-in for a
# native-Linux foreign-owned bind mount), but drive it via a caller-supplied
# --user instead of --user 0, so no root is ever used in this section.

# test_opencode_arbitrary_uid <sim-image>
# --user 999:0 (gid 0 as the *primary* group): home tree writable, git happy,
# and — unlike the --user 0 legacy path — no runtime uid/gid rewrite happens.
test_opencode_arbitrary_uid() {
    local sim=$1 out rc
    out=$(docker run --rm --user 999:0 \
        -v "$work_dir/fake-write-opencode.sh:/usr/local/bin/opencode:ro" \
        "$sim" --version 2>&1); rc=$?
    assert_exit0 "opencode: arbitrary-uid (999:0) exit code" "$rc" "$out"
    assert_contains "opencode: arbitrary-uid identity" "$out" "probe uid=999 gid=0"
    assert_contains "opencode: arbitrary-uid git works" "$out" "git-status OK"
    assert_contains "opencode: arbitrary-uid config writable" "$out" "write-config OK"
    assert_contains "opencode: arbitrary-uid data writable" "$out" "write-data OK"
    assert_not_contains "opencode: arbitrary-uid runs no uid/gid rewrite" "$out" "adapting uid/gid"
}

# test_opencode_arbitrary_uid_supp_gid <sim-image>
# The recommended recipe: gid 0 as a *supplementary* group, primary uid/gid
# matching the caller exactly (reproduces the --user 0 legacy path's file-
# ownership outcome with zero root).
test_opencode_arbitrary_uid_supp_gid() {
    local sim=$1 out rc
    out=$(docker run --rm --user 999:999 --group-add 0 \
        -v "$work_dir/fake-write-opencode.sh:/usr/local/bin/opencode:ro" \
        "$sim" --version 2>&1); rc=$?
    assert_exit0 "opencode: arbitrary-uid recommended recipe exit code" "$rc" "$out"
    assert_contains "opencode: arbitrary-uid recommended recipe identity" "$out" "probe uid=999 gid=999"
    assert_contains "opencode: arbitrary-uid recommended recipe config writable" "$out" "write-config OK"
    assert_contains "opencode: arbitrary-uid recommended recipe data writable" "$out" "write-data OK"
}

# test_opencode_arbitrary_uid_negative <sim-image>
# Guards against the home tree accidentally being world-writable: without
# gid 0 in any form, an arbitrary uid must NOT be able to write it.
test_opencode_arbitrary_uid_negative() {
    local sim=$1 out rc
    out=$(docker run --rm --user 999:999 \
        -v "$work_dir/fake-write-opencode.sh:/usr/local/bin/opencode:ro" \
        "$sim" --version 2>&1); rc=$?
    assert_contains "opencode: arbitrary-uid without gid 0 cannot write config" "$out" "write-config FAIL"
}

# test_opencode_arbitrary_uid_hardened <sim-image>
# The plan's headline security claim: the arbitrary-uid recipe works with
# zero capabilities and a read-only root filesystem — --user 0 cannot do
# this (see test_hardened_adaptation's minimal-capability-set requirement).
test_opencode_arbitrary_uid_hardened() {
    local sim=$1 out rc
    out=$(docker run --rm \
        --read-only --cap-drop=ALL --security-opt=no-new-privileges \
        --user 999:0 \
        --tmpfs /tmp:rw,nosuid,nodev \
        --tmpfs /home/ai-agent-box:rw,nosuid,nodev,uid=999,gid=0,mode=0770 \
        -v "$work_dir/fake-write-opencode.sh:/usr/local/bin/opencode:ro" \
        "$sim" --version 2>&1); rc=$?
    assert_exit0 "opencode: arbitrary-uid hardened (no caps, read-only)" "$rc" "$out"
    assert_contains "opencode: arbitrary-uid hardened config writable" "$out" "write-config OK"
}

# test_opencode_arbitrary_uid_ssh <sim-image>
# ensure_passwd_entry must let ssh/whoami resolve an otherwise-unrecognized
# uid; without it, openssh-client refuses to run at all.
test_opencode_arbitrary_uid_ssh() {
    local sim=$1 out rc
    out=$(docker run --rm --user 999:0 \
        -v "$work_dir/fake-identity.sh:/usr/local/bin/opencode:ro" \
        "$sim" --version 2>&1); rc=$?
    assert_exit0 "opencode: arbitrary-uid ssh probe exit code" "$rc" "$out"
    assert_contains "opencode: arbitrary-uid ssh resolves uid" "$out" "ssh=OpenSSH_"
}

# test_opencode_default_identity <image>
# The zero-`--user` default must stay byte-for-byte identical to before this
# change: uid=10001 gid=10001, home tree fully writable via ownership, not
# via the gid-0 mechanism.
test_opencode_default_identity() {
    local image=$1 out rc
    out=$(docker run --rm \
        -v "$work_dir/fake-write-opencode.sh:/usr/local/bin/opencode:ro" \
        "$image" --version 2>&1); rc=$?
    assert_exit0 "opencode: default identity exit code" "$rc" "$out"
    assert_contains "opencode: default identity unchanged (10001:10001)" "$out" "probe uid=10001 gid=10001"
    assert_contains "opencode: default identity config writable" "$out" "write-config OK"
    assert_contains "opencode: default identity data writable" "$out" "write-data OK"
}

# test_omp_arbitrary_uid <sim-image>
test_omp_arbitrary_uid() {
    local sim=$1 out rc
    out=$(docker run --rm --user 999:0 \
        -v "$work_dir/fake-write-omp.sh:/usr/local/bin/omp:ro" \
        "$sim" --version 2>&1); rc=$?
    assert_exit0 "omp: arbitrary-uid (999:0) exit code" "$rc" "$out"
    assert_contains "omp: arbitrary-uid identity" "$out" "probe uid=999 gid=0"
    assert_contains "omp: arbitrary-uid git works" "$out" "git-status OK"
    assert_contains "omp: arbitrary-uid home writable" "$out" "write-home OK"
    assert_contains "omp: arbitrary-uid agent writable" "$out" "write-agent OK"
    assert_not_contains "omp: arbitrary-uid runs no uid/gid rewrite" "$out" "adapting uid/gid"
}

# test_omp_arbitrary_uid_supp_gid <sim-image>
test_omp_arbitrary_uid_supp_gid() {
    local sim=$1 out rc
    out=$(docker run --rm --user 999:999 --group-add 0 \
        -v "$work_dir/fake-write-omp.sh:/usr/local/bin/omp:ro" \
        "$sim" --version 2>&1); rc=$?
    assert_exit0 "omp: arbitrary-uid recommended recipe exit code" "$rc" "$out"
    assert_contains "omp: arbitrary-uid recommended recipe identity" "$out" "probe uid=999 gid=999"
    assert_contains "omp: arbitrary-uid recommended recipe home writable" "$out" "write-home OK"
    assert_contains "omp: arbitrary-uid recommended recipe agent writable" "$out" "write-agent OK"
}

# test_omp_arbitrary_uid_negative <sim-image>
test_omp_arbitrary_uid_negative() {
    local sim=$1 out rc
    out=$(docker run --rm --user 999:999 \
        -v "$work_dir/fake-write-omp.sh:/usr/local/bin/omp:ro" \
        "$sim" --version 2>&1); rc=$?
    assert_contains "omp: arbitrary-uid without gid 0 cannot write home" "$out" "write-home FAIL"
}

# test_omp_arbitrary_uid_hardened <sim-image>
test_omp_arbitrary_uid_hardened() {
    local sim=$1 out rc
    out=$(docker run --rm \
        --read-only --cap-drop=ALL --security-opt=no-new-privileges \
        --user 999:0 \
        --tmpfs /tmp:rw,nosuid,nodev \
        --tmpfs /home/ai-agent-box:rw,nosuid,nodev,uid=999,gid=0,mode=0770 \
        -v "$work_dir/fake-write-omp.sh:/usr/local/bin/omp:ro" \
        "$sim" --version 2>&1); rc=$?
    assert_exit0 "omp: arbitrary-uid hardened (no caps, read-only)" "$rc" "$out"
    assert_contains "omp: arbitrary-uid hardened home writable" "$out" "write-home OK"
}

# test_omp_arbitrary_uid_ssh <sim-image>
test_omp_arbitrary_uid_ssh() {
    local sim=$1 out rc
    out=$(docker run --rm --user 999:0 \
        -v "$work_dir/fake-identity.sh:/usr/local/bin/omp:ro" \
        "$sim" --version 2>&1); rc=$?
    assert_exit0 "omp: arbitrary-uid ssh probe exit code" "$rc" "$out"
    assert_contains "omp: arbitrary-uid ssh resolves uid" "$out" "ssh=OpenSSH_"
}

# test_omp_default_identity <image>
test_omp_default_identity() {
    local image=$1 out rc
    out=$(docker run --rm \
        -v "$work_dir/fake-write-omp.sh:/usr/local/bin/omp:ro" \
        "$image" --version 2>&1); rc=$?
    assert_exit0 "omp: default identity exit code" "$rc" "$out"
    assert_contains "omp: default identity unchanged (10001:10001)" "$out" "probe uid=10001 gid=10001"
    assert_contains "omp: default identity home writable" "$out" "write-home OK"
    assert_contains "omp: default identity agent writable" "$out" "write-agent OK"
}

# --- opencode ---------------------------------------------------------------

test_opencode_default() {
    oc_ver=$(docker run --rm "$oc_image" --version 2>/dev/null)
    case "$oc_ver" in
        [0-9]*.[0-9]*.[0-9]*) ok "opencode: default --version ($oc_ver)" ;;
        *) bad "opencode: default --version" "unexpected output: '$oc_ver'" ;;
    esac
}

test_opencode_adaptation() {
    local sim="sim-oc:$run_id" out rc
    if ! make_sim "$oc_image" "$sim"; then
        bad "opencode: adaptation" "sim image build failed"
        return
    fi
    out=$(run_adaptation "$sim" "$work_dir/fake-write-opencode.sh" /usr/local/bin/opencode); rc=$?
    assert_exit0 "opencode: adaptation exit code" "$rc" "$out"
    assert_contains "opencode: adaptation message" "$out" "adapting uid/gid to mounted workspace owner 999:999"
    assert_contains "opencode: adapted identity" "$out" "probe uid=999 gid=999"
    assert_contains "opencode: git works in workspace" "$out" "git-status OK"
    assert_contains "opencode: ~/.config/opencode writable" "$out" "write-config OK"
    assert_contains "opencode: ~/.local/share/opencode writable" "$out" "write-data OK"
}

# --- omp --------------------------------------------------------------------

test_omp_default() {
    omp_ver=$(docker run --rm "$omp_image" --version 2>/dev/null)
    case "$omp_ver" in
        omp/[0-9]*.[0-9]*.[0-9]*) ok "omp: default --version ($omp_ver)" ;;
        *) bad "omp: default --version" "unexpected output: '$omp_ver'" ;;
    esac
}

test_omp_adaptation() {
    local sim="sim-omp:$run_id" out rc
    if ! make_sim "$omp_image" "$sim"; then
        bad "omp: adaptation" "sim image build failed"
        return
    fi
    out=$(run_adaptation "$sim" "$work_dir/fake-write-omp.sh" /usr/local/bin/omp); rc=$?
    assert_exit0 "omp: adaptation exit code" "$rc" "$out"
    assert_contains "omp: adaptation message" "$out" "adapting uid/gid to mounted workspace owner 999:999"
    assert_contains "omp: adapted identity" "$out" "probe uid=999 gid=999"
    assert_contains "omp: git works in workspace" "$out" "git-status OK"
    assert_contains "omp: ~/.omp writable" "$out" "write-home OK"
    assert_contains "omp: ~/.omp/agent writable" "$out" "write-agent OK"
}

# ~/.omp bind-mounted (no agent/ inside), root + adaptation: the entrypoint
# must not create or chown anything inside the mount — omp manages its own
# tree under a mounted ~/.omp.
test_omp_mounted_home() {
    local sim="sim-omp:$run_id" host_dir="$work_dir/mount-omp-home" out rc
    mkdir -p "$host_dir"
    out=$(docker run --rm --user 0 -v "$host_dir:/home/ai-agent-box/.omp" "$sim" --version 2>&1); rc=$?
    assert_exit0 "omp: mounted ~/.omp run exits 0" "$rc" "$out"
    assert_contains "omp: mounted ~/.omp still adapts" "$out" "adapting uid/gid"
    if [ -e "$host_dir/agent" ]; then
        bad "omp: entrypoint creates nothing inside mounted ~/.omp" "agent/ appeared in the host mount"
    else
        ok "omp: entrypoint creates nothing inside mounted ~/.omp"
    fi
}

# ~/.omp/agent bind-mounted as its own mount: the entrypoint adapts, chowns
# the unmounted parent, and leaves the mounted agent dir untouched.
test_omp_mounted_agent() {
    local sim="sim-omp:$run_id" host_dir="$work_dir/mount-omp-agent" out rc
    mkdir -p "$host_dir"
    out=$(docker run --rm --user 0 \
        -v "$work_dir/fake-readonly.sh:/usr/local/bin/omp:ro" \
        -v "$host_dir:/home/ai-agent-box/.omp/agent" \
        "$sim" --version 2>&1); rc=$?
    assert_exit0 "omp: mounted ~/.omp/agent run exits 0" "$rc" "$out"
    assert_contains "omp: mounted ~/.omp/agent still adapts" "$out" "adapting uid/gid"
    assert_contains "omp: mounted ~/.omp/agent adapted identity" "$out" "probe uid=999 gid=999"
    if [ -z "$(ls -A "$host_dir" 2>/dev/null)" ]; then
        ok "omp: mounted ~/.omp/agent left untouched"
    else
        bad "omp: mounted ~/.omp/agent left untouched" "host mount now contains: $(find "$host_dir" -mindepth 1 -maxdepth 1 | tr '\n' ' ')"
    fi
}

# Non-root with ~/.omp mounted: the entrypoint must not abort (it skips all
# writes into the mount and lets omp create what it needs).
test_omp_nonroot_mounted_home() {
    local host_dir="$work_dir/mount-omp-nonroot" out rc
    mkdir -p "$host_dir"
    out=$(docker run --rm -v "$host_dir:/home/ai-agent-box/.omp" "$omp_image" --version 2>&1); rc=$?
    assert_exit0 "omp: non-root with mounted ~/.omp does not abort" "$rc" "$out"
    assert_contains "omp: non-root mounted run prints version" "$out" "omp/"
}

# --- java -------------------------------------------------------------------

test_java_default() {
    local tool
    java_ver=$(docker run --rm "$java_image" --version 2>/dev/null)
    case "$java_ver" in
        [0-9]*.[0-9]*.[0-9]*) ok "java: default --version ($java_ver)" ;;
        *) bad "java: default --version" "unexpected output: '$java_ver'" ;;
    esac
    tool=$(docker run --rm --entrypoint bash "$java_image" \
        -c 'java -version 2>&1 | head -1 && mvnd --version 2>&1 | head -1 && python3 --version' 2>&1)
    assert_contains "java: JDK present" "$tool" "openjdk"
    assert_contains "java: mvnd present" "$tool" "mvnd"
    assert_contains "java: python3 present" "$tool" "Python"
}

test_java_adaptation() {
    local sim="sim-java:$run_id" out rc
    if ! make_sim "$java_image" "$sim"; then
        bad "java: adaptation" "sim image build failed"
        return
    fi
    out=$(run_adaptation "$sim" "$work_dir/fake-write-opencode.sh" /usr/local/bin/opencode); rc=$?
    assert_exit0 "java: adaptation exit code" "$rc" "$out"
    assert_contains "java: adaptation message" "$out" "adapting uid/gid to mounted workspace owner 999:999"
    assert_contains "java: adapted identity" "$out" "probe uid=999 gid=999"
    assert_contains "java: git works in workspace" "$out" "git-status OK"
    assert_contains "java: ~/.config/opencode writable" "$out" "write-config OK"
    assert_contains "java: ~/.local/share/opencode writable" "$out" "write-data OK"
}

# --- main -------------------------------------------------------------------

while [ $# -gt 0 ]; do
    case "$1" in
        --skip-build) skip_build=1 ;;
        --keep) keep=1 ;;
        --only)
            [ $# -ge 2 ] || die "--only needs a value"
            only=$(printf '%s' "$2" | tr ',' ' ')
            shift
            ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; die "unknown argument: $1" ;;
    esac
    shift
done

for v in $only; do
    case "$v" in
        opencode|omp|java) ;;
        *) die "--only: unknown variant '$v' (expected: opencode, omp, java)" ;;
    esac
done

docker info >/dev/null 2>&1 || die "docker daemon is not running (on macOS try: open -a Docker)"

write_fixtures
test_entrypoint_syntax

if want opencode; then
    if [ "$skip_build" -eq 0 ]; then
        build_image opencode opencode/opencode.Dockerfile "$oc_image"
    fi
    if have_image "$oc_image"; then
        test_opencode_default
        test_shellcheck "$oc_image" opencode
        test_opencode_adaptation
        test_serve "$oc_image" opencode "$oc_serve_port" "$oc_ver"
        test_serve_override "$oc_image" opencode "$oc_override_port"
        test_hardened_default "$oc_image" opencode
        test_hardened_adaptation "sim-oc:$run_id" "$work_dir/fake-write-opencode.sh" /usr/local/bin/opencode opencode
        test_opencode_default_identity "$oc_image"
        test_opencode_arbitrary_uid "sim-oc:$run_id"
        test_opencode_arbitrary_uid_supp_gid "sim-oc:$run_id"
        test_opencode_arbitrary_uid_negative "sim-oc:$run_id"
        test_opencode_arbitrary_uid_hardened "sim-oc:$run_id"
        test_opencode_arbitrary_uid_ssh "sim-oc:$run_id"
    else
        bad "opencode: image present" "$oc_image not found (build failed, or run without --skip-build)"
    fi
fi

if want omp; then
    if [ "$skip_build" -eq 0 ]; then
        build_image omp omp/omp.Dockerfile "$omp_image"
    fi
    if have_image "$omp_image"; then
        test_omp_default
        test_shellcheck "$omp_image" omp
        test_omp_adaptation
        test_omp_mounted_home
        test_omp_mounted_agent
        test_omp_nonroot_mounted_home
        test_hardened_default "$omp_image" omp
        test_hardened_adaptation "sim-omp:$run_id" "$work_dir/fake-write-omp.sh" /usr/local/bin/omp omp
        test_omp_default_identity "$omp_image"
        test_omp_arbitrary_uid "sim-omp:$run_id"
        test_omp_arbitrary_uid_supp_gid "sim-omp:$run_id"
        test_omp_arbitrary_uid_negative "sim-omp:$run_id"
        test_omp_arbitrary_uid_hardened "sim-omp:$run_id"
        test_omp_arbitrary_uid_ssh "sim-omp:$run_id"
    else
        bad "omp: image present" "$omp_image not found (build failed, or run without --skip-build)"
    fi
fi

if want java; then
    if [ "$skip_build" -eq 0 ]; then
        # java derives from the opencode image; make sure the base exists.
        have_image "$oc_image" || build_image opencode opencode/opencode.Dockerfile "$oc_image"
        build_image java java/java.25.Dockerfile "$java_image" --build-arg BASE_IMAGE="$oc_image"
    fi
    if have_image "$java_image"; then
        test_java_default
        test_shellcheck "$java_image" java
        test_java_adaptation
        test_serve "$java_image" java "$java_serve_port" "$java_ver"
        test_serve_override "$java_image" java "$java_override_port"
        test_hardened_default "$java_image" java
        test_hardened_adaptation "sim-java:$run_id" "$work_dir/fake-write-opencode.sh" /usr/local/bin/opencode java
    else
        bad "java: image present" "$java_image not found (build failed, or run without --skip-build)"
    fi
fi

printf '\n----------------------------------------\n'
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
