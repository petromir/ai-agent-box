# syntax=docker/dockerfile:1

# Dev image: ai-agent-box + a JVM/Python toolchain for agent-assisted builds.
# SDKMAN was considered and rejected: it is per-user (writes to $HOME, which
# the base entrypoint may re-own), depends on a live version catalog (not
# reproducible), and its runtime version-switching has no container use case.
# Instead, toolchains are pinned, checksum-verified tarballs installed
# system-wide — same philosophy as the base image.

# Bump to match the base image tag you built/pulled.
ARG BASE_IMAGE=ai-agent-box:latest
FROM ${BASE_IMAGE}

USER root

# Local-only escape hatch for TLS-intercepting corporate proxies, identical to
# the base image: appends a caller-supplied CA bundle before any network call.
# Never written to an image layer; builds without --secret are unaffected.
RUN --mount=type=secret,id=external_ca,required=false \
    if [ -s /run/secrets/external_ca ]; then \
      cat /run/secrets/external_ca >> /etc/ssl/certs/ca-certificates.crt; \
    fi

# --- Python 3.13 (native Wolfi package) ---
ARG PYTHON_VERSION=3.13
RUN apk add --no-cache \
    python-${PYTHON_VERSION} \
    py${PYTHON_VERSION}-pip

# --- Java 25 (BellSoft Liberica JDK, checksum-verified) ---
# Liberica is not in Wolfi (only upstream openjdk-25 is). BellSoft publishes
# tarballs via its GitHub releases; API: api.bell-sw.com/v1/liberica/releases.
# Rebuilds of the same version can change SHA1, so verify against the value
# captured when bumping: curl -s 'https://api.bell-sw.com/v1/liberica/releases?version=25.0.4.1&fields=sha1'
ARG LIBERICA_VERSION=25.0.4.1+1
ARG LIBERICA_SHA1_AMD64=4fd81f4fb5cbf77006a3973aaf110f8d7968f8dd
ARG LIBERICA_SHA1_ARM64=bf7f3596ed67f60b55b0c7f10b99b14493c535db
RUN arch="$(uname -m)" && \
    case "$arch" in \
      x86_64)  jdk_arch=amd64; sha="$LIBERICA_SHA1_AMD64" ;; \
      aarch64) jdk_arch=aarch64; sha="$LIBERICA_SHA1_ARM64" ;; \
      *) echo "unsupported arch: $arch" >&2; exit 1 ;; \
    esac && \
    if [ -z "$sha" ]; then echo "no Liberica SHA1 pinned for $arch; set LIBERICA_SHA1_* for your arch" >&2; exit 1; fi && \
    curl -fsSL -o /tmp/liberica.tar.gz \
      "https://github.com/bell-sw/Liberica/releases/download/${LIBERICA_VERSION}/bellsoft-jdk${LIBERICA_VERSION}-linux-${jdk_arch}.tar.gz" && \
    echo "${sha}  /tmp/liberica.tar.gz" | sha1sum -c - && \
    mkdir -p /usr/lib/jvm/liberica-25 && \
    tar -xzf /tmp/liberica.tar.gz -C /usr/lib/jvm/liberica-25 --strip-components=1 && \
    rm /tmp/liberica.tar.gz

ENV JAVA_HOME=/usr/lib/jvm/liberica-25 \
    PATH="/usr/lib/jvm/liberica-25/bin:${PATH}"

# --- Maven Daemon (mvnd) 1.0.x stable, checksum-verified ---
# Not packaged in Wolfi. Installed from archive.apache.org (the archive host
# keeps old releases, so pinned builds stay reproducible). mvnd bundles Maven;
# its daemon needs a JDK, provided by Liberica above.
ARG MVND_VERSION=1.0.6
ARG MVND_SHA256_AMD64=88fd474fd3f21b33ec1e6a75950f6abbe493d63a5e2b429475f5230b3ee6cb24
ARG MVND_SHA256_ARM64=e1d8071e172740ecd6a9c380938de69aafc7622218818c56e4d526cc761723c0
RUN arch="$(uname -m)" && \
    case "$arch" in \
      x86_64)  mvnd_arch=amd64; sha="$MVND_SHA256_AMD64" ;; \
      aarch64) mvnd_arch=aarch64; sha="$MVND_SHA256_ARM64" ;; \
      *) echo "unsupported arch: $arch" >&2; exit 1 ;; \
    esac && \
    curl -fsSL -o /tmp/mvnd.tar.gz \
      "https://archive.apache.org/dist/maven/mvnd/${MVND_VERSION}/maven-mvnd-${MVND_VERSION}-linux-${mvnd_arch}.tar.gz" && \
    echo "${sha}  /tmp/mvnd.tar.gz" | sha256sum -c - && \
    mkdir -p /opt/mvnd && \
    tar -xzf /tmp/mvnd.tar.gz -C /opt/mvnd --strip-components=1 && \
    rm /tmp/mvnd.tar.gz

ENV PATH="/opt/mvnd/bin:${PATH}"

USER opencode
