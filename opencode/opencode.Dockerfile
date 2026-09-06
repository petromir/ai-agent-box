# syntax=docker/dockerfile:1

# --- Build stage: run the official OpenCode installer ---
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

# Tooling required by the installer script (tar already ships with wolfi-base)
RUN apk add --no-cache \
    bash \
    curl

# Pin a known-good release so `docker build -f opencode/opencode.Dockerfile .`
# is reproducible by default and the OCI version label below always matches
# what's actually installed.
# Override both --build-arg OPENCODE_VERSION and --build-arg VERSION together
# to bump or to pin a different release.
ARG OPENCODE_VERSION=1.18.29

# Official install command; drops the binary at $HOME/.opencode/bin/opencode.
# HOME is pinned explicitly: the base image config sets no HOME, so the install
# path must not depend on the build shell's passwd lookup.
ENV HOME=/root
RUN set -o pipefail && \
    curl -fsSL https://opencode.ai/install | VERSION=${OPENCODE_VERSION} bash

# --- Runtime stage: minimal image with a non-root user ---
FROM cgr.dev/chainguard/wolfi-base:latest@sha256:a31344ab2cb8618db84f535eec56f76f6178b142cb92cb2e48676cc2dcebea72

# Metadata for organization and automation. VERSION defaults to match
# OPENCODE_VERSION above so a plain `docker build -f opencode/opencode.Dockerfile .`
# produces an accurate label without extra args; keep the two in sync when bumping.
ARG REVISION=unknown
ARG VERSION=1.18.29
LABEL org.opencontainers.image.title="OpenCode" \
      org.opencontainers.image.description="AI coding agent for the terminal, installed via the official installer." \
      org.opencontainers.image.authors="Petromir Dzhunev" \
      org.opencontainers.image.source="https://github.com/petromir/ai-agent-box" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${REVISION}"

# Agent-efficiency tooling, version-pinned (stable Wolfi builds only) so a
# plain `docker build -f opencode/opencode.Dockerfile .` stays reproducible,
# same rationale as OPENCODE_VERSION above. Bump these independently via
# --build-arg as Wolfi ships new stable builds; check available versions with
# the Wolfi package index before bumping.
ARG RIPGREP_VERSION=15.2.0-r2
ARG JQ_VERSION=1.8.2-r1
ARG YQ_VERSION=4.53.6-r1
ARG PATCH_VERSION=2.8-r8
ARG DIFFUTILS_VERSION=3.12-r6

# Runtime dependencies: bash/curl for the commands the agent runs, git for
# repository awareness, openssh-client for git over SSH, setpriv for dropping
# root privileges to the runtime user at container start (util-linux's
# setpriv, not BusyBox's — BusyBox setpriv lacks --reuid/--regid).
# ripgrep is a fast, gitignore-aware search the agent's own tools shell out to
# instead of BusyBox grep; jq/yq give the agent single-call JSON and YAML
# querying/validation instead of dumping whole payloads into context; patch/
# diffutils let it apply unified diffs directly (patch has no BusyBox applet).
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
    diffutils=${DIFFUTILS_VERSION}

# UID/GID above 10,000 avoids overlapping with privileged host users.
# OpenCode persists config and sessions under $HOME, so the user needs a home directory.
RUN addgroup -g 10001 -S opencode && \
    adduser -u 10001 -S -G opencode -h /home/ai-agent-box opencode && \
    mkdir -p /workspace /home/ai-agent-box/.config/opencode \
             /home/ai-agent-box/.local/share/opencode && \
    chown -R opencode:opencode /workspace /home/ai-agent-box/.config \
                               /home/ai-agent-box/.local

# Adapts uid/gid to a bind-mounted /workspace owned by a host user (native Linux),
# marks it git-safe, and execs opencode as the final process. Reverts to plain
# opencode when no /workspace is mounted.
COPY --chmod=755 opencode/opencode-entrypoint.sh /usr/local/bin/opencode-entrypoint.sh

# Install the binary system-wide from the build stage
COPY --from=builder --chown=root:root --chmod=755 /root/.opencode/bin/opencode /usr/local/bin/opencode

# Documents the default `opencode serve` HTTP port (metadata only; does not
# publish — use `docker run -p 4096:4096` to expose it on the host).
EXPOSE 4096

ENV HOME=/home/ai-agent-box

WORKDIR /workspace

USER opencode

ENTRYPOINT ["opencode-entrypoint.sh"]

CMD ["--help"]
