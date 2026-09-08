#!/usr/bin/env bash
# Entrypoint for the OpenCode container.
#
# When /workspace is a bind mount owned by a host user (native Linux keeps the
# host uid/gid on mounts), the container's fixed uid 10001 cannot write to the
# repo and git refuses it with "detected dubious ownership". This script adapts
# the container identity to the mount owner, then drops privileges via
# `setpriv` (util-linux's setpriv, which supports --reuid/--regid unlike
# BusyBox's) directly into opencode. setpriv replaces its own process image via
# execve rather than forking a supervisor, so opencode itself ends up as PID 1
# — no wrapper process, nothing to reap, and signals/exit codes are exact.
#
# Requires the container to run with --user 0 for the adaptation path; without
# root the script logs a warning and continues as-is (Docker Desktop on macOS
# squashes ownership, so the default user works there unmodified).
set -euo pipefail

readonly mount_dir=/workspace
readonly home_dir=/home/ai-agent-box
readonly docker_sock=/var/run/docker.sock

log() { printf 'entrypoint: %s\n' "$*" >&2; }

is_mounted() {
    grep -qs " $1 " /proc/mounts
}

# Ensure ~/.config/opencode exists (OpenCode auto-creates it on first run, but
# we want it ready and owned by the runtime user). Ownership is fixed
# non-recursively and never touches bind-mounted host data.
ensure_config_dir() {
    if [ ! -d "${home_dir}/.config/opencode" ]; then
        mkdir -p "${home_dir}/.config/opencode"
        log "created ${home_dir}/.config/opencode"
    fi
    # After uid adaptation the pre-created tree is still owned by the image's
    # 10001; the adapted user cannot write to it. Skip bind mounts so host
    # file ownership is never altered.
    if [ "$(id -u)" = "0" ] && ! is_mounted "${home_dir}/.config"; then
        chown opencode:opencode "${home_dir}/.config"
        if ! is_mounted "${home_dir}/.config/opencode"; then
            chown opencode:opencode "${home_dir}/.config/opencode"
        fi
    fi
}

# Same ownership fix for the pre-created data tree (~/.local/share/opencode,
# where sessions/auth live and opencode writes repos/ on startup): after uid
# adaptation it is still owned by the image's 10001 and opencode fails with
# EACCES. Skip bind mounts (e.g. a persisted data dir from the host) so host
# file ownership is never altered.
ensure_data_dir() {
    if [ "$(id -u)" = "0" ] && ! is_mounted "${home_dir}/.local"; then
        chown opencode:opencode "${home_dir}/.local"
        if ! is_mounted "${home_dir}/.local/share"; then
            chown opencode:opencode "${home_dir}/.local/share"
            if ! is_mounted "${home_dir}/.local/share/opencode"; then
                chown opencode:opencode "${home_dir}/.local/share/opencode"
            fi
        fi
    fi
}

# Grants the runtime user access to a docker socket bind-mounted at
# /var/run/docker.sock (the "Docker-outside-of-Docker" pattern: this image
# ships only the docker CLI, no dockerd, so agent-issued `docker` commands
# reach the host's or Docker Desktop's daemon through the mounted socket).
# Access to the socket is gated by group membership, not uid, so we make
# opencode a supplementary member of the socket's owning group — the
# `--init-groups` on the setpriv exec below then picks it up automatically.
# Requires root (writing group membership needs /etc/group write access,
# same constraint as the uid/gid adaptation above); a no-op otherwise, and a
# no-op if no socket is mounted.
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
    addgroup opencode "${sock_group}"
    log "granted opencode access to ${docker_sock} via group ${sock_group} (gid ${sock_gid})"
}

# serve/web/acp default to --hostname 127.0.0.1 (loopback only), which is
# unreachable from the host through a published port. In a container we want
# the server bound to all interfaces so `docker run -p` reaches it out of the
# box. Inject --hostname 0.0.0.0 only for these headless-server subcommands
# (identified as the first non-flag argument, so a leading global flag like
# --print-logs doesn't defeat the match) and only when the user has not set
# --hostname themselves (they can still pass --hostname 127.0.0.1 to restrict
# to loopback). Runs before the uid-adaptation branch so both exec paths below
# receive the same args.
headless_cmd=""
for arg in "$@"; do
    case "$arg" in
        -*) continue ;;
        *) headless_cmd="$arg"; break ;;
    esac
done
case "$headless_cmd" in
    serve|web|acp)
        has_hostname=0
        for arg in "$@"; do
            case "$arg" in
                --hostname|--hostname=*) has_hostname=1; break ;;
            esac
        done
        if [ "$has_hostname" = "0" ]; then
            set -- "$1" --hostname 0.0.0.0 "${@:2}"
        fi
        ;;
esac

if [ "$(id -u)" = "0" ]; then
    if [ -d "${mount_dir}" ]; then
        owner_uid=$(stat -c %u "${mount_dir}")
        owner_gid=$(stat -c %g "${mount_dir}")

        current_uid=$(id -u opencode)
        current_gid=$(id -g opencode)

        if [ "${owner_uid}" != "0" ] && { [ "${owner_uid}" != "${current_uid}" ] || [ "${owner_gid}" != "${current_gid}" ]; }; then
            log "adapting uid/gid to mounted workspace owner ${owner_uid}:${owner_gid}"
            # Change the runtime identity itself, not just this process: every
            # child the agent spawns (git, bash tools) must match the owner.
            sed -i -E "s/^opencode:x:[0-9]+:[0-9]+:/opencode:x:${owner_uid}:${owner_gid}:/" /etc/passwd
            sed -i -E "s/^opencode:x:[0-9]+:/opencode:x:${owner_gid}:/" /etc/group
            # HOME must belong to the adapted identity (non-recursive: a
            # user-mounted config volume inside is left as-is). Skip when HOME
            # itself is a bind mount so host file ownership is never altered.
            if ! is_mounted "${home_dir}"; then
                chown opencode:opencode "${home_dir}"
            fi

            ensure_config_dir
            ensure_data_dir
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
    # current process image in place: opencode ends up running as PID 1 with
    # no supervising process above it. --bounding-set -all clears every
    # capability from the bounding set (not just effective/permitted, which a
    # plain uid drop already clears) and --no-new-privs prevents regaining
    # privilege via setuid/file-capability binaries — defense in depth in
    # case a derived image (see README: "Using this image as a base")
    # reintroduces one as root before this exec runs.
    exec setpriv --reuid opencode --regid opencode --init-groups \
        --bounding-set -all --no-new-privs \
        -- env HOME="${home_dir}" opencode "$@"
fi

# Non-root invocation: trust any workspace mounted at a well-known path.
if [ -d "${mount_dir}" ]; then
    log "running without root; uid/gid adaptation skipped (see README: native Linux file ownership)"
    git config --global --add safe.directory "${mount_dir}" || true
fi

ensure_config_dir

exec opencode "$@"
