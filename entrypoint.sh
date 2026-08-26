#!/usr/bin/env bash
# Entrypoint for the OpenCode container.
#
# When /workspace is a bind mount owned by a host user (native Linux keeps the
# host uid/gid on mounts), the container's fixed uid 10001 cannot write to the
# repo and git refuses it with "detected dubious ownership". This script adapts
# the container identity to the mount owner and then execs opencode.
#
# Requires the container to run with --user 0 for the adaptation path; without
# root the script logs a warning and continues as-is (Docker Desktop on macOS
# squashes ownership, so the default user works there unmodified).
set -euo pipefail

readonly mount_dir=/workspace
readonly home_dir=/home/ai-agent-box

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

# opencode serve defaults to --hostname 127.0.0.1 (loopback only), which is
# unreachable from the host through a published port. In a container we want
# the server bound to all interfaces so `docker run -p` reaches it out of the
# box. Inject --hostname 0.0.0.0 only when the subcommand is `serve` and the
# user has not set --hostname themselves (they can still pass
# --hostname 127.0.0.1 to restrict to loopback). Runs before the uid-adaptation
# branch so both exec paths below receive the same args.
if [ "${1:-}" = "serve" ]; then
    has_hostname=0
    for arg in "$@"; do
        case "$arg" in
            --hostname|--hostname=*) has_hostname=1; break ;;
        esac
    done
    if [ "$has_hostname" = "0" ]; then
        set -- "$1" --hostname 0.0.0.0 "${@:2}"
    fi
fi

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
            # user-mounted config volume inside is left as-is).
            chown opencode:opencode "${home_dir}"

            ensure_config_dir
        fi
    fi

    # Trust the workspace for git regardless of who owns it, so the agent's
    # git operations never fail on "dubious ownership".
    git config --system --add safe.directory /workspace

    exec runuser -u opencode -- env HOME="${home_dir}" opencode "$@"
fi

# Non-root invocation: trust any workspace mounted at a well-known path.
if [ -d "${mount_dir}" ]; then
    log "running without root; uid/gid adaptation skipped (see README: native Linux file ownership)"
    git config --global --add safe.directory /workspace || true
fi

ensure_config_dir

exec opencode "$@"
