#!/usr/bin/env bash
# Entrypoint for the omp (Oh-My-Pi) container.
#
# Mirrors opencode/opencode-entrypoint.sh (see there for the full rationale): when /workspace is
# a bind mount owned by a host user (native Linux keeps the host uid/gid on
# mounts), the container's fixed uid 10001 cannot write to the repo and git
# refuses it with "detected dubious ownership". This script adapts the
# container identity to the mount owner, then drops privileges via `setpriv`
# (util-linux's setpriv, which supports --reuid/--regid unlike BusyBox's)
# directly into omp. setpriv replaces its own process image via execve rather
# than forking a supervisor, so omp itself ends up as PID 1 — no wrapper
# process, nothing to reap, and signals/exit codes are exact.
#
# Requires the container to run with --user 0 for the adaptation path; without
# root the script logs a warning and continues as-is (Docker Desktop on macOS
# squashes ownership, so the default user works there unmodified).
#
# Deliberately does NOT inject --hostname for any subcommand (unlike
# opencode/opencode-entrypoint.sh): omp has no HTTP serve mode — its entry points are the TUI,
# one-shot `-p`, RPC, and ACP over stdio — and injecting a flag into `acp`
# would break the stdio protocol.
set -euo pipefail

readonly mount_dir=/workspace
readonly home_dir=/home/ai-agent-box
readonly docker_sock=/var/run/docker.sock

log() { printf 'entrypoint: %s\n' "$*" >&2; }

is_mounted() {
    grep -qs " $1 " /proc/mounts
}

# Ensure ~/.omp/agent exists (omp auto-creates it on first run, but we want it
# ready and owned by the runtime user). omp keeps its config and sessions there
# (~/.omp/agent/config.yml, models.yml, ...). Ownership is fixed non-recursively
# and never touches bind-mounted host data.
ensure_config_dir() {
    # If ~/.omp is a bind mount we never write into it at all: creating or
    # chowning ~/.omp/agent there would alter host file ownership (and, as
    # root, leave a root-owned dir the adapted user cannot write to). omp
    # creates ~/.omp/agent itself on first run under the mounted dir.
    if is_mounted "${home_dir}/.omp"; then
        return
    fi
    if [ ! -d "${home_dir}/.omp/agent" ]; then
        mkdir -p "${home_dir}/.omp/agent"
        log "created ${home_dir}/.omp/agent"
    fi
    # After uid adaptation the pre-created tree is still owned by the image's
    # 10001; the adapted user cannot write to it. Re-own both levels
    # non-recursively, skipping ~/.omp/agent itself if it is its own bind mount
    # (so that host file ownership is never altered).
    if [ "$(id -u)" = "0" ]; then
        chown omp:omp "${home_dir}/.omp"
        if ! is_mounted "${home_dir}/.omp/agent"; then
            chown omp:omp "${home_dir}/.omp/agent"
        fi
    fi
}

# Grants the runtime user access to a docker socket bind-mounted at
# /var/run/docker.sock (the "Docker-outside-of-Docker" pattern: this image
# ships only the docker CLI, no dockerd, so agent-issued `docker` commands
# reach the host's or Docker Desktop's daemon through the mounted socket).
# Access to the socket is gated by group membership, not uid, so we make omp
# a supplementary member of the socket's owning group — the `--init-groups`
# on the setpriv exec below then picks it up automatically. Requires root
# (writing group membership needs /etc/group write access, same constraint
# as the uid/gid adaptation above); a no-op otherwise, and a no-op if no
# socket is mounted.
ensure_docker_access() {
    if [ ! -S "${docker_sock}" ]; then
        return
    fi
    sock_gid=$(stat -c %g "${docker_sock}")
    sock_group=$(awk -F: -v gid="${sock_gid}" '$3==gid{print $1; exit}' /etc/group)
    if [ -z "${sock_group}" ]; then
        sock_group=docker-host
        addgroup -g "${sock_gid}" "${sock_group}"
    fi
    addgroup omp "${sock_group}"
    log "granted omp access to ${docker_sock} via group ${sock_group} (gid ${sock_gid})"
}

# Non-root counterpart to ensure_docker_access: without root we cannot write
# /etc/group, so a mounted docker socket is not auto-wired on the
# arbitrary-uid path. Advisory only (never fails the container) — names the
# flag you must add yourself.
advise_docker_socket_nonroot() {
    if [ ! -S "${docker_sock}" ]; then
        return
    fi
    sock_gid=$(stat -c %g "${docker_sock}")
    case " $(id -G) " in
        *" ${sock_gid} "*) return ;;
    esac
    log "docker socket mounted but gid ${sock_gid} is not in your groups; add --group-add ${sock_gid} to access it"
}

# Self-heals /etc/passwd for an arbitrary, otherwise-unrecognized uid (the
# "arbitrary uid" pattern used by omp.Dockerfile: gid 0 makes the home tree
# writable for any uid, but adds no passwd entry for it — openssh-client
# refuses to run as a uid it cannot look up, which would otherwise break
# git-over-SSH). Requires /etc/passwd to be group-writable (baked into the
# image); non-fatal if it isn't (e.g. --read-only without a writable /etc),
# since only ssh needs this, not omp itself.
ensure_passwd_entry() {
    if id -un >/dev/null 2>&1; then
        return
    fi
    if printf 'omp:x:%s:%s:omp:%s:/bin/sh\n' "$(id -u)" "$(id -g)" "${home_dir}" \
        2>/dev/null >> /etc/passwd; then
        log "added a passwd entry for uid $(id -u) (needed for ssh/whoami)"
    else
        log "could not add a passwd entry for uid $(id -u) (read-only /etc?); ssh may not work"
    fi
}

if [ "$(id -u)" = "0" ]; then
    if [ -d "${mount_dir}" ]; then
        owner_uid=$(stat -c %u "${mount_dir}")
        owner_gid=$(stat -c %g "${mount_dir}")

        current_uid=$(id -u omp)
        current_gid=$(id -g omp)

        if [ "${owner_uid}" != "0" ] && { [ "${owner_uid}" != "${current_uid}" ] || [ "${owner_gid}" != "${current_gid}" ]; }; then
            log "adapting uid/gid to mounted workspace owner ${owner_uid}:${owner_gid}"
            # Change the runtime identity itself, not just this process: every
            # child the agent spawns (git, bash tools) must match the owner.
            sed -i -E "s/^omp:x:[0-9]+:[0-9]+:/omp:x:${owner_uid}:${owner_gid}:/" /etc/passwd
            sed -i -E "s/^omp:x:[0-9]+:/omp:x:${owner_gid}:/" /etc/group
            # HOME must belong to the adapted identity (non-recursive: a
            # user-mounted config volume inside is left as-is). Skip when HOME
            # itself is a bind mount so host file ownership is never altered.
            if ! is_mounted "${home_dir}"; then
                chown omp:omp "${home_dir}"
            fi

            ensure_config_dir
        elif [ "${owner_uid}" = "0" ]; then
            log "mounted workspace is owned by root; uid/gid adaptation skipped"
        fi
    fi

    # Trust the workspace for git regardless of who owns it, so the agent's
    # git operations never fail on "dubious ownership". Non-fatal: a
    # read-only /etc (e.g. --read-only without a writable overlay) would
    # otherwise abort the whole container under `set -e` for a step that is
    # only a convenience, not a correctness requirement.
    git config --system --add safe.directory "${mount_dir}" \
        || log "could not write /etc/gitconfig (read-only /etc?); continuing without it"

    ensure_docker_access

    # setpriv execve's its target directly (no fork), so this replaces the
    # current process image in place: omp ends up running as PID 1 with
    # no supervising process above it. --bounding-set -all clears every
    # capability from the bounding set (not just effective/permitted, which a
    # plain uid drop already clears) and --no-new-privs prevents regaining
    # privilege via setuid/file-capability binaries — defense in depth in
    # case a derived image reintroduces one as root before this exec runs.
    exec setpriv --reuid omp --regid omp --init-groups \
        --bounding-set -all --no-new-privs \
        -- env HOME="${home_dir}" omp "$@"
fi

# Non-root invocation: trust any workspace mounted at a well-known path.
# git's dubious-ownership check is already satisfied by the build-time
# `git config --system --add safe.directory '*'` (see omp.Dockerfile), so
# no runtime git config is needed here — unlike the legacy --user 0 path.
if [ -d "${mount_dir}" ]; then
    log "running without root; for a foreign-owned /workspace on native Linux, pass --user \"\$(id -u):\$(id -g)\" --group-add 0 (see README: On native Linux)"
fi

advise_docker_socket_nonroot
ensure_passwd_entry
ensure_config_dir

exec omp "$@"
