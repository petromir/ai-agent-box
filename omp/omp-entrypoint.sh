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
    # git operations never fail on "dubious ownership".
    git config --system --add safe.directory "${mount_dir}"

    # setpriv execve's its target directly (no fork), so this replaces the
    # current process image in place: omp ends up running as PID 1 with
    # no supervising process above it.
    exec setpriv --reuid omp --regid omp --init-groups -- env HOME="${home_dir}" omp "$@"
fi

# Non-root invocation: trust any workspace mounted at a well-known path.
if [ -d "${mount_dir}" ]; then
    log "running without root; uid/gid adaptation skipped (see README: native Linux file ownership)"
    git config --global --add safe.directory "${mount_dir}" || true
fi

ensure_config_dir

exec omp "$@"
