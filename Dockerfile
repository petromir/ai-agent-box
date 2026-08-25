# syntax=docker/dockerfile:1

# --- Build stage: run the official OpenCode installer ---
FROM cgr.dev/chainguard/wolfi-base:latest@sha256:a31344ab2cb8618db84f535eec56f76f6178b142cb92cb2e48676cc2dcebea72 AS builder

# Tooling required by the installer script (tar already ships with wolfi-base)
RUN apk add --no-cache \
    bash \
    curl

# Empty OPENCODE_VERSION installs the latest release; set it to pin (e.g. 1.0.180)
ARG OPENCODE_VERSION=

# Official install command; drops the binary at $HOME/.opencode/bin/opencode.
# HOME is pinned explicitly: the base image config sets no HOME, so the install
# path must not depend on the build shell's passwd lookup.
ENV HOME=/root
RUN set -o pipefail && \
    curl -fsSL https://opencode.ai/install | VERSION=${OPENCODE_VERSION} bash

# --- Runtime stage: minimal image with a non-root user ---
FROM cgr.dev/chainguard/wolfi-base:latest@sha256:a31344ab2cb8618db84f535eec56f76f6178b142cb92cb2e48676cc2dcebea72

# Metadata for organization and automation
ARG REVISION
ARG VERSION=latest
LABEL org.opencontainers.image.title="OpenCode" \
      org.opencontainers.image.description="AI coding agent for the terminal, installed via the official installer." \
      org.opencontainers.image.authors="Petromir Dzhunev" \
      org.opencontainers.image.source="https://github.com/petromir/ai-agent-box" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${REVISION}"

# Runtime dependencies: bash/curl for the commands the agent runs, git for
# repository awareness, openssh-client for git over SSH, util-linux-su for
# runuser (drops privileges to the runtime user at container start)
RUN apk add --no-cache \
    bash \
    curl \
    git \
    openssh-client \
    util-linux-su

# UID/GID above 10,000 avoids overlapping with privileged host users.
# OpenCode persists config and sessions under $HOME, so the user needs a home directory.
RUN addgroup -g 10001 -S opencode && \
    adduser -u 10001 -S -G opencode -h /home/opencode opencode && \
    mkdir -p /workspace /home/opencode/.config/opencode && \
    chown -R opencode:opencode /workspace /home/opencode/.config

# Adapts uid/gid to a bind-mounted /workspace owned by a host user (native Linux),
# marks it git-safe, and execs opencode as the final process. Reverts to plain
# opencode when no /workspace is mounted.
COPY --chmod=755 entrypoint.sh /usr/local/bin/entrypoint.sh

# Install the binary system-wide from the build stage
COPY --from=builder --chown=root:root --chmod=755 /root/.opencode/bin/opencode /usr/local/bin/opencode

ENV HOME=/home/opencode

WORKDIR /workspace

USER opencode

ENTRYPOINT ["entrypoint.sh"]

CMD ["--help"]
