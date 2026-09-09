# syntax=docker/dockerfile:1

# --- Build stage: run the official Oh-My-Pi (omp) installer ---
FROM cgr.dev/chainguard/wolfi-base:latest@sha256:a31344ab2cb8618db84f535eec56f76f6178b142cb92cb2e48676cc2dcebea72 AS builder

# Local-only escape hatch for TLS-intercepting corporate proxies: appends a
# caller-supplied CA bundle to the base image's trust store before any network
# call. The secret is mounted into a tmpfs for this RUN only — it is never
# written to an image layer, so builds without --secret are unaffected
# (required=false) and the CA never ships to anyone pulling this image.
RUN --mount=type=secret,id=external_ca,required=false \
    if [ -s /run/secrets/external_ca ]; then \
      cat /run/secrets/external_ca >> /etc/ssl/certs/ca-certificates.crt; \
    fi

# Tooling required by the installer script
RUN apk add --no-cache \
    bash \
    curl

# Pin a known-good release so `docker build -f omp/omp.Dockerfile .` is
# reproducible by default and the OCI version label below always matches
# what's actually installed. --binary keeps the installer on the prebuilt
# GitHub-release binary path (--ref alone would switch it to a from-source
# install via bun). Override both --build-arg OMP_VERSION and --build-arg
# VERSION together to bump or to pin a different release.
ARG OMP_VERSION=v18.1.11

# Official install command; drops the binary at $HOME/.local/bin/omp. The
# installer smoke-tests `omp --version` after download and fails the build if
# the binary cannot start. HOME is pinned explicitly: the base image config
# sets no HOME, so the install path must not depend on the build shell's
# passwd lookup.
ENV HOME=/root
RUN set -o pipefail && \
    curl -fsSL https://omp.sh/install | sh -s -- --binary --ref ${OMP_VERSION}

# fff-mcp (https://github.com/dmtrKovalenko/fff): a static MCP server binary.
# Deliberately NOT installed via the vendor's `curl | bash` installer
# (https://dmtrkovalenko.dev/install-fff-mcp.sh) — that script is itself
# fetched unpinned from a mutable path and its own checksum verification
# fails open (warns and continues) in some fallback branches. Instead: pinned
# version + pinned per-architecture SHA256, downloaded directly from the
# GitHub release and verified the same way as Liberica/mvnd in
# java/java.25.Dockerfile — fail closed on unsupported arch or checksum
# mismatch.
ARG FFF_MCP_VERSION=v0.10.6
ARG FFF_MCP_SHA256_AMD64=a44ef64015f1754aa63b690c24d9a748ed16298f05350da7b09554c4c98dfb0f
ARG FFF_MCP_SHA256_ARM64=028b9e388716a8c0c39de3f153dd8e14e5ee998ffa70d4951f1cd2a3fc42f6ce
RUN arch="$(uname -m)" && \
    case "$arch" in \
      x86_64)  target=x86_64-unknown-linux-musl; sha="$FFF_MCP_SHA256_AMD64" ;; \
      aarch64) target=aarch64-unknown-linux-musl; sha="$FFF_MCP_SHA256_ARM64" ;; \
      *) echo "unsupported arch: $arch" >&2; exit 1 ;; \
    esac && \
    if [ -z "$sha" ]; then echo "no fff-mcp SHA256 pinned for $arch; set FFF_MCP_SHA256_* for your arch" >&2; exit 1; fi && \
    curl -fsSL -o /tmp/fff-mcp \
      "https://github.com/dmtrKovalenko/fff/releases/download/${FFF_MCP_VERSION}/fff-mcp-${target}" && \
    echo "${sha}  /tmp/fff-mcp" | sha256sum -c - && \
    chmod +x /tmp/fff-mcp

# --- Runtime stage: minimal image with a non-root user ---
FROM cgr.dev/chainguard/wolfi-base:latest@sha256:a31344ab2cb8618db84f535eec56f76f6178b142cb92cb2e48676cc2dcebea72

# Metadata for organization and automation. VERSION defaults to match
# OMP_VERSION above so a plain build produces an accurate label without extra
# args; keep the two in sync when bumping.
ARG REVISION=unknown
ARG VERSION=v18.1.11
LABEL org.opencontainers.image.title="omp (Oh-My-Pi)" \
      org.opencontainers.image.description="AI coding agent with the IDE wired in, installed via the official installer." \
      org.opencontainers.image.authors="Petromir Dzhunev" \
      org.opencontainers.image.source="https://github.com/petromir/ai-agent-box" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${REVISION}"

# Agent-efficiency tooling, version-pinned (stable Wolfi builds only) so a
# plain build stays reproducible, same rationale as OMP_VERSION above. Bump
# these independently via --build-arg as Wolfi ships new stable builds; check
# available versions with the Wolfi package index before bumping.
ARG RIPGREP_VERSION=15.2.0-r2
ARG JQ_VERSION=1.8.2-r1
ARG YQ_VERSION=4.53.6-r1
ARG PATCH_VERSION=2.8-r8
ARG DIFFUTILS_VERSION=3.12-r6
ARG DOCKER_CLI_VERSION=29.8.0-r0

# Runtime dependencies: bash/curl for the commands the agent runs, git for
# repository awareness, openssh-client for git over SSH, setpriv for dropping
# root privileges to the runtime user at container start (util-linux's
# setpriv, not BusyBox's — BusyBox setpriv lacks --reuid/--regid).
# ripgrep is a fast, gitignore-aware search for shell invocations; jq/yq give
# single-call JSON and YAML querying/validation instead of dumping whole
# payloads into context; patch/diffutils let the agent apply unified diffs
# directly (patch has no BusyBox applet).
# docker-cli is the client binary only (no dockerd — that would need
# privileged mode and contradicts "keep the image minimal"): the agent talks
# to the host's or Docker Desktop's daemon over a bind-mounted
# /var/run/docker.sock ("Docker-outside-of-Docker"); see README for the
# `-v /var/run/docker.sock:/var/run/docker.sock` usage and the
# omp-entrypoint.sh group-membership wiring that grants the runtime user
# access to it.
RUN --mount=type=secret,id=external_ca,required=false \
    if [ -s /run/secrets/external_ca ]; then \
      cat /run/secrets/external_ca >> /etc/ssl/certs/ca-certificates.crt; \
    fi
RUN apk add --no-cache \
    bash \
    curl \
    git \
    openssh-client \
    setpriv \
    ripgrep=${RIPGREP_VERSION} \
    jq=${JQ_VERSION} \
    yq=${YQ_VERSION} \
    patch=${PATCH_VERSION} \
    diffutils=${DIFFUTILS_VERSION} \
    docker-cli=${DOCKER_CLI_VERSION}

# UID/GID above 10,000 avoids overlapping with privileged host users.
# omp persists config and sessions under $HOME (~/.omp/agent), so the user needs a home directory.
#
# Ownership follows the "arbitrary uid" pattern (the OpenShift/Kubernetes
# convention): gid 0 owns the tree and group permission bits mirror the
# owner's (chmod g=u), so ANY uid carrying gid 0 — as its primary group or as
# a supplementary one, e.g. `docker run --user 1000:1000 --group-add 0` — can
# read/write it, with no root required inside the container at any point.
# `chmod g+s` on directories re-applies the setgid bit (which `chmod -R g=u`
# otherwise clears) so new subdirectories keep inheriting gid 0. The user's
# own primary group stays `omp` (gid 10001), so the zero-`--user` default is
# unaffected — only the *directory* group ownership changes.
RUN addgroup -g 10001 -S omp && \
    adduser -u 10001 -S -G omp -h /home/ai-agent-box omp && \
    mkdir -p /workspace /home/ai-agent-box/.omp/agent && \
    chown -R omp:0 /workspace /home/ai-agent-box/.omp && \
    chmod -R g=u /workspace /home/ai-agent-box/.omp && \
    find /workspace /home/ai-agent-box/.omp -type d -exec chmod g+s {} +

# Bakes git's trust for any workspace this container ever operates on — the
# whole point of this image is running against foreign-owned bind mounts —
# so an arbitrary-uid run needs no runtime `git config` at all. `'*'` (not
# just /workspace) also covers nested repos under /workspace, which the
# legacy --user 0 path's runtime-only equivalent (see omp-entrypoint.sh)
# does not.
RUN git config --system --add safe.directory '*'

# Lets the entrypoint self-heal /etc/passwd for an arbitrary, otherwise-
# unrecognized uid (see ensure_passwd_entry in omp-entrypoint.sh): openssh-
# client refuses to run as a uid it cannot look up, which would otherwise
# break git-over-SSH under the arbitrary-uid pattern above. Safe: the image
# ships no setuid/setgid binaries and no sudo/su/doas (see README: "Using
# this image as a base"), so group-write access to these two files alone
# confers no privilege-escalation path.
RUN chmod g=u /etc/passwd /etc/group

# Adapts uid/gid to a bind-mounted /workspace owned by a host user (native Linux),
# marks it git-safe, and execs omp as the final process. Reverts to plain
# omp when no /workspace is mounted.
COPY --chmod=755 omp/omp-entrypoint.sh /usr/local/bin/omp-entrypoint.sh

# Install the binary system-wide from the build stage
COPY --from=builder --chown=root:root --chmod=755 /root/.local/bin/omp /usr/local/bin/omp

# fff-mcp: static system binary, root-owned, same placement convention as
# omp above — not user state, so no arbitrary-uid ownership handling.
COPY --from=builder --chown=root:root --chmod=755 /tmp/fff-mcp /usr/local/bin/fff-mcp

# No EXPOSE: omp has no HTTP server mode — its entry points are the TUI,
# one-shot `-p`, RPC, and ACP over stdio — so there is no port to document
# (unlike the opencode image's 4096).

ENV HOME=/home/ai-agent-box

WORKDIR /workspace

USER omp

ENTRYPOINT ["omp-entrypoint.sh"]

CMD ["--help"]
