# ai-agent-box

A minimal, hardening-first container runtime for [OpenCode](https://opencode.ai) —
the AI coding agent for your terminal — built on
[Chainguard Wolfi](https://github.com/chainguard-images/images/tree/main/images/wolfi-base)
with a pinned digest, a non-root user, and an entrypoint that transparently
adapts to bind-mounted repositories.

## Why

Running an AI coding agent directly on your machine gives it full access to
your environment. This image gives the agent an isolated, ephemeral, minimal
Linux userland instead — while still letting it work on your real repository
through a bind mount, with files it creates owned by **you** on native Linux
(not by a container uid).

## Build

```bash
# Default: builds the pinned OpenCode release (see OPENCODE_VERSION in Dockerfile)
docker build -t ai-agent-box:latest .

# Pin a different OpenCode release (bump OPENCODE_VERSION and VERSION together
# so the installed binary and the OCI version label stay in sync)
docker build --build-arg OPENCODE_VERSION=1.18.23 --build-arg VERSION=1.18.23 -t ai-agent-box:1.18.23 .

# Pin a different version of a bundled tool (ripgrep, jq, yq, patch, diffutils)
docker build --build-arg JQ_VERSION=1.8.2-r1 -t ai-agent-box:latest .

# OCI revision metadata
docker build --build-arg REVISION="$(git rev-parse --short HEAD)" .
```

### Building behind a TLS-intercepting proxy

Corporate networks that TLS-inspect traffic (Zscaler, Netskope, and similar)
break `apk add`/`curl` inside the build with `certificate verify failed`,
because the base image's trust store only has public root CAs — it has never
seen your proxy's private root. Fix it for your build only, without baking
the CA into the shipped image, using a BuildKit secret:

```bash
docker build --secret id=external_ca,src=/path/to/your-ca-bundle.pem -t ai-agent-box:latest .
```

- The secret is mounted into a tmpfs for that build step only; it is never
  written to an image layer, so it never ships in the image you push or share.
- Builds without `--secret` are unaffected — this is an opt-in local escape
  hatch, not a required build input.
- Get your proxy's root CA from your OS trust store (e.g. macOS Keychain
  Access → System keychain → export the root certificate authority your
  security tooling installed) since it's already trusted there for your
  browser to work behind the same proxy.

## Run

### Interactive TUI

> On native Linux, if your host uid is not `10001`, add `--user 0` so the
> entrypoint can adapt file ownership to your repo — see
> [On native Linux (file ownership)](#on-native-linux-file-ownership).

```bash
cd your-project
docker run -it --rm \
  -v "$PWD:/workspace" \
  -v "$HOME/.local/share/opencode:/home/ai-agent-box/.local/share/opencode" \
  ai-agent-box:latest
```

- `-v "$PWD:/workspace"` — your repository, the agent's working directory
- `-v "$HOME/.local/share/opencode:..."` — optional; persists sessions/auth
  across containers so you don't re-login on every run

### Passing configuration and skills from outside

OpenCode reads its configuration from `~/.config/opencode/`. You can inject
your own configuration, custom agents, and skills by mounting files or
directories from the host:

```bash
# Full config directory (opencode.json, agents/, skills/)
docker run -it --rm \
  -v "$PWD:/workspace" \
  -v "$HOME/.config/opencode:/home/ai-agent-box/.config/opencode" \
  ai-agent-box:latest

# Individual config file only
docker run -it --rm \
  -v "$PWD:/workspace" \
  -v "$HOME/.config/opencode/opencode.json:/home/ai-agent-box/.config/opencode/opencode.json" \
  ai-agent-box:latest

# Custom skills directory
docker run -it --rm \
  -v "$PWD:/workspace" \
  -v "$HOME/.config/opencode/skills:/home/ai-agent-box/.config/opencode/skills" \
  ai-agent-box:latest
```

Container paths:
| Host path | Container mount | Purpose |
|-----------|----------------|---------|
| `~/.config/opencode/` | `/home/ai-agent-box/.config/opencode/` | Full config: `opencode.json`, agents, skills |
| `~/.config/opencode/opencode.json` | `/home/ai-agent-box/.config/opencode/opencode.json` | Main configuration file |
| `~/.config/opencode/agents/` | `/home/ai-agent-box/.config/opencode/agents/` | Custom agent definitions |
| `~/.config/opencode/skills/` | `/home/ai-agent-box/.config/opencode/skills/` | Custom skill definitions |

The entrypoint creates `~/.config/opencode` on first run if it does not exist.
When you bind-mount a directory over it, the mount replaces the container
directory — your host files are used as-is.

### Non-interactive

```bash
docker run -it --rm -v "$PWD:/workspace" ai-agent-box:latest run "explain this repo"
docker run --rm -v "$PWD:/workspace" ai-agent-box:latest --version
```

### Server (`opencode serve`)

Run OpenCode as a headless HTTP server (no TUI). The image auto-binds the
server to `0.0.0.0` in serve mode so a published port reaches it — you don't
need to pass `--hostname` yourself.

```bash
docker run --rm -d -p 4096:4096 -v "$PWD:/workspace" --name oc-serve ai-agent-box:latest serve
```

- `-p 4096:4096` — publish the default serve port to the host
- `-d` — detached (long-running server)
- `-v "$PWD:/workspace"` — your repository (the server operates on it)

Check health:

```bash
curl http://localhost:4096/global/health
# {"healthy":true,"version":"..."}
```

OpenAPI 3.1 spec (generate clients / inspect types):

```bash
open http://localhost:4096/doc
```

Stop the server:

```bash
docker stop oc-serve
```

> Note: the opencode server does not install a graceful-shutdown handler, so
> it ignores SIGTERM/SIGINT and `docker stop` force-stops it after the grace
> period (default 10 s). The entrypoint execs opencode as PID 1 (directly, or
> via `setpriv` when adapting uid/gid with `--user 0` — `setpriv` replaces its
> own process image rather than forking, so opencode still ends up as PID 1),
> so signals reach it directly; this is an upstream behavior, not an
> entrypoint issue. For immediate teardown use `docker kill oc-serve`
> (SIGKILL). With `--rm` the container is removed once stopped.

#### Options

| Flag | Description | Default |
|------|-------------|---------|
| `--port` | Port to listen on | `4096` |
| `--hostname` | Hostname to bind (image defaults to `0.0.0.0` in serve mode) | `127.0.0.1`* |
| `--cors` | Additional browser origins (repeatable) | `[]` |
| `--mdns` | Enable mDNS discovery | `false` |
| `--mdns-domain` | Custom mDNS domain name | — |

\* The upstream `127.0.0.1` default is loopback-only and unreachable from the
host through a published port; the image injects `--hostname 0.0.0.0` when you
run `serve` without an explicit `--hostname`. Pass `--hostname 127.0.0.1` to
restrict to loopback, or any other value to customize.

Override port and restrict to loopback (only reachable via `docker exec` or
`--network host`, since a loopback-bound server is not reachable through a
published port):

```bash
docker run --rm -d -v "$PWD:/workspace" --name oc-lb ai-agent-box:latest serve --port 4097 --hostname 127.0.0.1
docker exec oc-lb curl -s http://localhost:4097/global/health
```

Allow browser origins (CORS):

```bash
docker run --rm -p 4096:4096 -v "$PWD:/workspace" \
  ai-agent-box:latest serve --cors http://localhost:5173 --cors https://app.example.com
```

#### Authentication

Protect the server with HTTP basic auth:

```bash
docker run --rm -d -p 4096:4096 -v "$PWD:/workspace" \
  -e OPENCODE_SERVER_PASSWORD=your-password \
  ai-agent-box:latest serve
```

The username defaults to `opencode`; override with
`-e OPENCODE_SERVER_USERNAME=custom`. Without a password, opencode logs
`server is unsecured` on startup.

#### Persistence

Mount the auth/sessions directory so logins and sessions survive across
containers:

```bash
docker run --rm -d -p 4096:4096 -v "$PWD:/workspace" \
  -v "$HOME/.local/share/opencode:/home/ai-agent-box/.local/share/opencode" \
  ai-agent-box:latest serve
```

On native Linux with a host uid other than `10001`, start as root so the
entrypoint adapts the container identity to your repo (works the same in serve
mode): `docker run --rm -d --user 0 -p 4096:4096 -v "$PWD:/workspace" ai-agent-box:latest serve`.

> Note: mDNS discovery (`--mdns`) relies on host multicast and typically does
> not function inside a container without `--network host`; the flags are
> passed through but mDNS may be inactive.

### On native Linux (file ownership)

Bind mounts keep host uid/gid. If your host uid differs from the image's
10001, files the agent creates would be owned by 10001 — and git would refuse
the repo as "dubious ownership". Start the container as root and let the
entrypoint match your identity automatically:

```bash
docker run -it --rm --user 0 -v "$PWD:/workspace" ai-agent-box:latest
```

The entrypoint rewrites the runtime user's uid/gid to the mount owner, marks
`/workspace` git-safe, then drops privileges before exec'ing OpenCode. On
Docker Desktop (macOS/Windows) ownership is squashed and the default non-root
invocation works as-is.

## Image details

| Property | Value |
|----------|-------|
| Base | `cgr.dev/chainguard/wolfi-base` (digest-pinned) |
| User | `opencode`, uid/gid 10001 (root only at entry for uid adaptation) |
| Binary | `/usr/local/bin/opencode` (root-owned, 0755, from the official installer) |
| Data dirs | `$HOME=/home/ai-agent-box` (writable), `WORKDIR=/workspace` |
| Size | ~251 MB (approximate; varies by opencode release) |
| Entry | `entrypoint.sh` → `opencode`; default `CMD ["--help"]` |
| Exposed | `4096/tcp` (default `opencode serve` port; metadata only) |

Runtime packages: `bash`, `curl`, `git`, `openssh-client`, `setpriv`
(util-linux's setpriv, used to drop root privileges to the runtime user at
container start), plus version-pinned agent-efficiency tooling: `ripgrep`
(fast, gitignore-aware search), `jq` and `yq` (JSON/YAML querying and
validation), `patch` and `diffutils` (applying unified diffs). Pin each with
its own `--build-arg` (`RIPGREP_VERSION`, `JQ_VERSION`, `YQ_VERSION`,
`PATCH_VERSION`, `DIFFUTILS_VERSION`) — same reproducibility rationale as
`OPENCODE_VERSION`. The build stage runs the official installer
(`curl -fsSL https://opencode.ai/install | bash`) and copies only the binary
into the final image — no install toolchain in the runtime layer.

## Using this image as a base

You can layer extra tools (Python, Java, Maven, etc.) on top of this image by
using it as a base in your own Dockerfile:

```dockerfile
FROM ai-agent-box:latest

# The runtime stage ends on `USER opencode` (uid 10001), so switch back to
# root to install packages, then drop privileges again.
USER root

RUN apk add --no-cache \
    python3 \
    openjdk-17 \
    maven

USER opencode
```

Things to keep in mind:

- **Switch to `USER root` before `apk add`, then back to `USER opencode`.**
  The base image is non-root by default; installing packages needs root, but
  the final image should stay non-root unless you have a specific reason not
  to.
- **Verify Wolfi package names before installing.** This image is built on
  Chainguard Wolfi, whose package names sometimes differ from Alpine's (or
  don't exist at all). Check first:
  ```bash
  docker run --rm cgr.dev/chainguard/wolfi-base:latest sh -c 'apk search <pkg>'
  ```
- **`ENTRYPOINT`/`CMD` are inherited automatically.** Unless you want
  different default behavior, leave them as-is so your derived image still
  runs OpenCode. Override `CMD` (or `ENTRYPOINT`) explicitly if you need to.
- **Preserve ownership under `/home/ai-agent-box`.** Anything you `COPY` or
  create there should be `chown`ed to `opencode:opencode` (uid/gid 10001), or
  the runtime user won't be able to write to it.
- **Reuse the TLS-intercepting-proxy pattern if needed.** If you're behind a
  corporate MITM proxy, mount an external CA the same way this repo's
  Dockerfile does (see [Building behind a TLS-intercepting
  proxy](#building-behind-a-tls-intercepting-proxy)) before your own
  `apk add`/`curl` calls.
- **Expect the image to grow.** Toolchains like a JDK and Maven add real
  weight (often 300–500 MB combined); the "minimal" sizing in this README
  applies to the unmodified base image, not your derived one.

## API keys

OpenCode stores provider credentials under
`~/.local/share/opencode/auth.json` (inside the container:
`/home/ai-agent-box/.local/share/opencode/`). Either persist that directory as a
volume (shown above) or pass keys per-run with `-e`:

```bash
docker run -it --rm -v "$PWD:/workspace" -e ANTHROPIC_API_KEY ai-agent-box:latest
```

Note: on native Linux with `--user 0`, the entrypoint adapts the container
user to your host uid. If the persisted `opencode` data directory on the host
was created by an earlier run with a different uid (e.g. the image's 10001),
fix its ownership once with `sudo chown -R "$(id -u):$(id -g)" ~/.local/share/opencode`,
or the agent will not be able to write sessions/auth.

## License

Apache-2.0 — see [LICENSE](LICENSE).

## Support my work

<a href="https://ko-fi.com/petromirdzhunev" target="_blank"><img src="https://raw.githubusercontent.com/petromir/petromir/refs/heads/master/assets/kofi-button.svg" alt="Buy Me A Ko-fi" style="height: 45px !important;width: 163px !important;" ></a>
<a href="https://www.buymeacoffee.com/petromirdzhunev" target="_blank"><img src="https://raw.githubusercontent.com/petromir/petromir/refs/heads/master/assets/bmc-button.svg" alt="Buy Me A Coffee" style="height: 45px !important;width: 163px !important;" ></a>
<a href="https://github.com/sponsors/petromir" target="_blank"><img src="https://raw.githubusercontent.com/petromir/petromir/refs/heads/master/assets/github-sponsor-button.svg" alt="GitHub Sponsor" style="height: 45px !important;width: 163px !important;" ></a>
