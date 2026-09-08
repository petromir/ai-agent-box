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

The image and entrypoint are built to be safe by default (non-root, no
setuid binaries, no privilege-escalation path back to root). But containers
are not a full sandbox out of the box: capabilities, the network namespace,
and the root filesystem are only as locked down as the flags you pass to
`docker run`. See [Hardening: keeping the agent scoped to
`/workspace`](#hardening-keeping-the-agent-scoped-to-workspace) for the flags
that close that gap.

Prefer [omp](https://omp.sh) (Oh-My-Pi) over OpenCode? The same box is
available as the [omp variant](#variant-omp-oh-my-pi).

## Build

```bash
# Default: builds the pinned OpenCode release (see OPENCODE_VERSION in opencode/opencode.Dockerfile)
docker build -f opencode/opencode.Dockerfile -t ai-agent-box:latest .

# Pin a different OpenCode release (bump OPENCODE_VERSION and VERSION together
# so the installed binary and the OCI version label stay in sync)
docker build -f opencode/opencode.Dockerfile --build-arg OPENCODE_VERSION=1.18.29 --build-arg VERSION=1.18.29 -t ai-agent-box:1.18.29 .

# Pin a different version of a bundled tool (ripgrep, jq, yq, patch, diffutils)
docker build -f opencode/opencode.Dockerfile --build-arg JQ_VERSION=1.8.2-r1 -t ai-agent-box:latest .

# OCI revision metadata
docker build -f opencode/opencode.Dockerfile --build-arg REVISION="$(git rev-parse --short HEAD)" .
```

### Building behind a TLS-intercepting proxy

Corporate networks that TLS-inspect traffic (Zscaler, Netskope, and similar)
break `apk add`/`curl` inside the build with `certificate verify failed`,
because the base image's trust store only has public root CAs — it has never
seen your proxy's private root. Fix it for your build only, without baking
the CA into the shipped image, using a BuildKit secret:

```bash
docker build -f opencode/opencode.Dockerfile --secret id=external_ca,src=/path/to/your-ca-bundle.pem -t ai-agent-box:latest .
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

> On native Linux, if your host uid is not `10001`, add `--user
> "$(id -u):$(id -g)" --group-add 0` so the agent can write its config/data
> dirs with no root involved — see [On native Linux (file
> ownership)](#on-native-linux-file-ownership).

```bash
cd your-project
docker run -it --rm \
  --user "$(id -u):$(id -g)" --group-add 0 \
  -v "$PWD:/workspace" \
  -v "$HOME/.local/share/opencode:/home/ai-agent-box/.local/share/opencode" \
  ai-agent-box:latest
```

- `--user "$(id -u):$(id -g)" --group-add 0` — native Linux only; matches
  your host uid/gid exactly (files the agent creates come out owned by you)
  while adding gid 0 as an extra group so the pre-baked config/data dirs are
  writable. Omit this on macOS/Windows (Docker Desktop already squashes
  bind-mount ownership) or if your host uid happens to be `10001`.
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
server to `0.0.0.0` *inside the container* in serve mode so a published port
reaches it — you don't need to pass `--hostname` yourself. The server is the
agent's control plane: it can read/write everything under `/workspace` and
run shell commands, so publish it to loopback only and always set a password.

```bash
docker run --rm -d -p 127.0.0.1:4096:4096 -v "$PWD:/workspace" \
  -e OPENCODE_SERVER_PASSWORD="$(openssl rand -hex 24)" \
  --name opencode-server ai-agent-box:latest serve
```

- `-p 127.0.0.1:4096:4096` — publish the serve port to loopback **only**;
  omitting the `127.0.0.1:` prefix (or using `-P`, since the image also
  declares `EXPOSE 4096`) publishes on **all** host interfaces, reachable by
  anyone on your LAN/VPN
- `-e OPENCODE_SERVER_PASSWORD=...` — required; without it the server accepts
  unauthenticated requests (see [Authentication](#authentication) below)
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
docker stop opencode-server
```

> Note: the opencode server does not install a graceful-shutdown handler, so
> it ignores SIGTERM/SIGINT and `docker stop` force-stops it after the grace
> period (default 10 s). The entrypoint execs opencode as PID 1 (directly, or
> via `setpriv` when adapting uid/gid with `--user 0` — `setpriv` replaces its
> own process image rather than forking, so opencode still ends up as PID 1),
> so signals reach it directly; this is an upstream behavior, not an
> entrypoint issue. For immediate teardown use `docker kill opencode-server`
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

Override port and restrict to loopback *inside the container too* (only
reachable via `docker exec`, since a loopback-bound server is not reachable
through a published port at all):

```bash
docker run --rm -d -v "$PWD:/workspace" --name oc-lb ai-agent-box:latest serve --port 4097 --hostname 127.0.0.1
docker exec oc-lb curl -s http://localhost:4097/global/health
```

> Do not reach for `--network host` to work around this instead — it removes
> the container's network namespace entirely, so *every* service listening on
> your host's loopback interface (databases, other dev servers, a
> TCP-exposed Docker daemon) becomes directly reachable from inside the
> container. `docker exec` (above) is the safe way to probe a
> loopback-bound server from outside the container.

Allow browser origins (CORS):

```bash
docker run --rm -p 127.0.0.1:4096:4096 -v "$PWD:/workspace" \
  -e OPENCODE_SERVER_PASSWORD="$(openssl rand -hex 24)" \
  ai-agent-box:latest serve --cors http://localhost:5173 --cors https://app.example.com
```

#### Authentication

Protect the server with HTTP basic auth — treat this as **required**, not
optional, for any serve invocation, even one published to loopback only
(anything else on your machine, or anyone with SSH access to it, can reach a
loopback-bound port):

```bash
docker run --rm -d -p 127.0.0.1:4096:4096 -v "$PWD:/workspace" \
  -e OPENCODE_SERVER_PASSWORD="$(openssl rand -hex 24)" \
  ai-agent-box:latest serve
```

The username defaults to `opencode`; override with
`-e OPENCODE_SERVER_USERNAME=custom`. Without a password, opencode logs
`server is unsecured` on startup — treat that log line as a misconfiguration,
not a warning to ignore.

#### Persistence

Mount the auth/sessions directory so logins and sessions survive across
containers:

```bash
docker run --rm -d -p 127.0.0.1:4096:4096 -v "$PWD:/workspace" \
  -v "$HOME/.local/share/opencode:/home/ai-agent-box/.local/share/opencode" \
  -e OPENCODE_SERVER_PASSWORD="$(openssl rand -hex 24)" \
  ai-agent-box:latest serve
```

On native Linux with a host uid other than `10001`, add
`--user "$(id -u):$(id -g)" --group-add 0` (works the same in serve mode, no
root involved): `docker run --rm -d --user "$(id -u):$(id -g)" --group-add 0 -p 127.0.0.1:4096:4096 -v "$PWD:/workspace" -e OPENCODE_SERVER_PASSWORD="$(openssl rand -hex 24)" ai-agent-box:latest serve`.

> Note: mDNS discovery (`--mdns`) relies on host multicast and typically does
> not function inside a container without `--network host`. Given the
> network-isolation trade-off `--network host` carries (see above), treat
> `--mdns` as effectively unsupported in this image rather than reaching for
> that flag to make it work.

### On native Linux (file ownership)

Bind mounts keep host uid/gid. If your host uid differs from the image's
`10001`, the agent needs to write its config/data dirs (and, for git, avoid
"dubious ownership" on `/workspace`) as a uid it doesn't own by default.

**Recommended: the arbitrary-uid recipe (no root, ever):**

```bash
docker run -it --rm \
  --user "$(id -u):$(id -g)" --group-add 0 \
  -v "$PWD:/workspace" \
  ai-agent-box:latest
```

- `--user "$(id -u):$(id -g)"` — runs the container as your exact host uid
  and gid, so files the agent creates in `/workspace` are owned by you, not
  by a container-internal uid.
- `--group-add 0` — adds gid `0` as an *extra* group (not your primary
  group), which is all that's needed to write `~/.config/opencode` and
  `~/.local/share/opencode` inside the container. See "Why gid 0?" below for
  what this does and doesn't mean.
- git's dubious-ownership check is a non-issue here: the image bakes
  `git config --system --add safe.directory '*'` at build time, so it
  trusts any workspace regardless of uid — no runtime step needed.
- One-time setup, not a per-run burden: put the command in a shell alias
  or function (`alias agent-box='docker run -it --rm --user "$(id -u):$(id -g)" --group-add 0 -v "$PWD:/workspace" ai-agent-box:latest'`),
  or use the [Compose snippet](#compose-snippet) below.

**Legacy alternative: `--user 0`.** Still supported, not removed, but no
longer recommended for new setups — it briefly runs the container as real
root so the entrypoint can rewrite its own uid/gid, whereas the recipe above
never uses root at all:

```bash
docker run -it --rm --user 0 -v "$PWD:/workspace" ai-agent-box:latest
```

The entrypoint rewrites the runtime user's uid/gid to the mount owner, marks
`/workspace` git-safe, then drops privileges before exec'ing OpenCode.

On Docker Desktop (macOS/Windows), ownership is squashed and the plain
default invocation (no `--user` flag at all) already works as-is — none of
the above is needed there.

### Why gid `0`?

If you're not familiar with Linux users/groups, here's the short version.
Every file has a numeric owner (**uid**) and a numeric group (**gid**). The
image can't predict which uid you'll run as, but it *can* pin one shared gid
in advance: it makes `~/.config/opencode`, `~/.local/share/opencode`, and
`$HOME` itself owned by group `0`, with group-write permission
(`chmod g=u`). Linux then lets **any** uid that carries gid `0` — as its
main group or as an extra one via `--group-add 0` — read and write those
directories, no matter what its own uid is.

```
# without --group-add 0:
$ docker run --user 1000:1000 ai-agent-box:latest run "..."
EACCES: permission denied, mkdir '/home/ai-agent-box/.local/share/opencode/log'

# with --group-add 0:
$ docker run --user 1000:1000 --group-add 0 ai-agent-box:latest run "..."
# works — id inside the container shows: uid=1000 gid=1000 groups=0(root),1000
```

Gid `0` happens to be called "root" on most Linux systems, which can sound
alarming — but inside this container it confers **no special power**: there
is no `sudo`, no setuid binary, nothing gid `0` can do beyond read/write the
few directories the image explicitly made group-writable. It's just a
convenient, always-present group number every container has, borrowed as a
"anyone with this group can write here" signal — not an admin flag. If a
security scanner in your environment flags `runAsGroup: 0`, use
`--group-add 0` (gid 0 as a supplementary group) rather than `--user X:0`
(gid 0 as your primary group) — both work identically for this image, and
the former keeps your primary gid as whatever your policy expects.

### Compose snippet

```yaml
services:
  agent:
    image: ai-agent-box:latest
    user: "${UID:-1000}:${GID:-1000}"
    group_add:
      - "0"
    volumes:
      - .:/workspace
    stdin_open: true
    tty: true
```

Run with `UID=$(id -u) GID=$(id -g) docker compose run --rm agent` (Compose
does not expand `$(id -u)` itself, so export it from the shell first).

## Hardening: keeping the agent scoped to `/workspace`

The image is non-root, has no setuid binaries, and no way back to root once
the entrypoint drops privileges — but a container is not a sandbox by
itself. Capabilities, the network namespace, and the root filesystem are only
as locked down as the flags you pass to `docker run`. The recipes below were
verified against this image; adopt them as your default invocation rather
than an occasional extra.

### Threat model in one paragraph

**Docker Desktop (macOS/Windows):** the container runs inside a lightweight
VM; an escape reaches that VM, not your host filesystem, and bind-mount
ownership is squashed so the default non-root user already works. **Native
Linux:** the kernel is shared with your host. Use the [arbitrary-uid
recipe](#on-native-linux-file-ownership) (`--user "$(id -u):$(id -g)"
--group-add 0`) rather than the legacy `--user 0`: it needs **no root and no
capabilities at all** (verified working with `--cap-drop=ALL`), so there is
no privileged window for an escape to land in, unlike `--user 0`, which
briefly runs the container as real root. Rootless Docker, `dockerd
--userns-remap`, or Podman with `--userns=keep-id` remain worth adopting on
top of either recipe if available — they add a further layer by remapping
container uids away from real host uids entirely.

### Recommended invocations

Default (non-root) path — verified working:

```bash
docker run -it --rm \
  --cap-drop=ALL \
  --security-opt=no-new-privileges \
  --pids-limit=512 --memory=4g --cpus=2 \
  -v "$PWD:/workspace" \
  ai-agent-box:latest
```

Add, if you don't need persisted sessions (verified working; omit the tmpfs
on `$HOME` if you bind-mount `~/.local/share/opencode` for persistence
instead, since that mount already gives you a writable, size-bounded path):

```bash
  --read-only \
  --tmpfs /tmp:rw,nosuid,nodev \
  --tmpfs /home/ai-agent-box:rw,nosuid,nodev,uid=10001,gid=10001
```

Native-Linux arbitrary-uid path (see [On native Linux (file
ownership)](#on-native-linux-file-ownership)) — this is the **recommended**
native-Linux recipe; unlike `--user 0` below, it needs **zero capabilities**
(verified working with `--cap-drop=ALL`) and is fully compatible with
`--read-only`:

```bash
docker run -it --rm \
  --user "$(id -u):$(id -g)" --group-add 0 \
  --cap-drop=ALL \
  --security-opt=no-new-privileges \
  --read-only \
  --tmpfs /tmp:rw,nosuid,nodev \
  --tmpfs /home/ai-agent-box:rw,nosuid,nodev,uid=$(id -u),gid=0,mode=0770 \
  --pids-limit=512 --memory=4g --cpus=2 \
  -v "$PWD:/workspace" \
  ai-agent-box:latest
```

(Omit the `--read-only`/`--tmpfs` lines if you don't need that level of
hardening — the recipe works identically without them, just with a writable
root filesystem.)

Legacy `--user 0` path — kept for compatibility, no longer recommended (see
[On native Linux (file ownership)](#on-native-linux-file-ownership)). This
is the **exact minimal capability set**; dropping `CAP_CHOWN` breaks the
entrypoint's `chown` calls, a plain `--cap-drop=ALL` fails at `setpriv`'s
`setresuid` with a non-obvious error, and dropping `CAP_SETPCAP` breaks the
entrypoint's own `setpriv --bounding-set -all` hardening step (that step
needs `CAP_SETPCAP` to clear the *target* process's bounding set, even
though the target ends up with none of these capabilities once it runs):

```bash
docker run -it --rm --user 0 \
  --cap-drop=ALL --cap-add=CHOWN --cap-add=SETUID --cap-add=SETGID --cap-add=SETPCAP \
  --security-opt=no-new-privileges \
  --pids-limit=512 --memory=4g --cpus=2 \
  -v "$PWD:/workspace" \
  ai-agent-box:latest
```

`--read-only` is **not compatible** with `--user 0`: the entrypoint needs a
writable `/etc` to rewrite `/etc/passwd`/`/etc/group`. This is one more
reason to prefer the arbitrary-uid recipe above when you can.

### Never mount / never pass

- **Never mount:** `/var/run/docker.sock` (equivalent to unrestricted host
  root — see the note below if you actually need Docker-outside-of-Docker),
  `/`, `$HOME` as a whole, `~/.ssh` as a whole, `~/.aws`, `~/.kube`,
  `~/.docker`.
- **Never pass:** `--privileged`, `--pid=host`, `--ipc=host`,
  `--security-opt seccomp=unconfined`, `--cap-add=SYS_ADMIN`. Don't forward
  `SSH_AUTH_SOCK` into the container either — it lets the agent authenticate
  as you anywhere your agent forwarding reaches, with no key file to revoke.
- **Do instead:** mount a single dedicated, revocable deploy key read-only
  (`-v "$HOME/.ssh/id_agentbox:/home/ai-agent-box/.ssh/id_ed25519:ro"`), or
  prefer an HTTPS token scoped to the one repo you're working on, passed with
  `-e`. Mount the narrowest directory the task actually needs, and add `:ro`
  to any mount the agent must not write to.
- **git-over-SSH and an arbitrary uid:** `ssh` refuses to run as a uid it
  cannot look up in `/etc/passwd` (e.g. `--user 999:0` with no such uid
  baked into the image). The entrypoint self-heals this by appending a
  passwd entry for the running uid on first use, so `ssh`/`whoami` work
  normally — no action needed on your part. If you also pass `--read-only`
  without a writable `/etc`, that self-heal can't run; either accept that
  SSH-based git won't work in that combination, or bind-mount your host's
  own passwd file read-only instead: `-v /etc/passwd:/etc/passwd:ro`.
- **`docker.sock` if you really need it:** `ensure_docker_access` in both
  entrypoints supports the Docker-outside-of-Docker pattern when running as
  `--user 0` (mount the host's socket, the entrypoint grants the runtime
  user group access to it automatically). On the recommended arbitrary-uid
  path this auto-wiring needs root and doesn't run, so add the socket's own
  group yourself: `--group-add "$(stat -c %g /var/run/docker.sock)"`. Either
  way, treat that mount as equivalent to handing the agent root on the
  Docker host, because it is — a container started through that socket can
  trivially mount `/` and read/write anything. Only do this in a disposable
  VM, never on a workstation with anything sensitive on it.

### Network

Verified: with default bridge networking the container can reach services
bound to your host's loopback interface (e.g. via `host.docker.internal`),
and the agent has unrestricted egress by default (it ships `curl`).
"Access to the host" is not only the filesystem — an agent with unrestricted
egress can also read cloud-metadata endpoints on a cloud VM, reach a
TCP-exposed Docker daemon, or exfiltrate repository contents to any endpoint
the model chooses to call.

- Use a dedicated user-defined bridge network rather than the default one.
- Use `--network=none` for anything that doesn't need model/API access (e.g.
  `--version`, or local-model setups reachable only via a mounted socket).
- For sensitive repositories, route egress through an allow-listing proxy
  (`-e HTTPS_PROXY=...`) so only your model provider's endpoint is reachable.
- Never pass `--network host` to work around a loopback-bound `serve` or
  `--mdns` (see [Server](#server-opencode-serve)) — it removes the container's
  network namespace entirely, making every host-loopback service directly
  reachable from inside the container.

### Filesystem and resource limits

- `--read-only` plus the tmpfs mounts above prevents the agent from
  persisting tooling or tampering with `/usr/local/bin/opencode` or `/etc`
  between invocations. Rely on the default seccomp profile too — never pass
  `--security-opt seccomp=unconfined` to work around a tool that seems to
  need it; narrow the actual cause instead.
- `--pids-limit`, `--memory`, and `--cpus` bound the blast radius of a
  runaway build, an agent stuck in a retry loop, or a shell fork bomb the
  agent's own tool-calling issues — none of which requires a container
  escape to hurt your host.
- A bind mount has no container-level disk quota: the agent can fill your
  host disk by writing into `/workspace` or a persisted volume. Monitor free
  space the same way you would for any other process writing to that path.

## Image details

| Property | Value |
|----------|-------|
| Base | `cgr.dev/chainguard/wolfi-base` (digest-pinned) |
| User | `opencode`, uid/gid 10001 (arbitrary-uid capable via gid 0; root only needed for the legacy `--user 0` path) |
| Binary | `/usr/local/bin/opencode` (root-owned, 0755, from the official installer) |
| Data dirs | `$HOME=/home/ai-agent-box` (writable), `WORKDIR=/workspace` |
| Size | ~251 MB (approximate; varies by opencode release) |
| Entry | `opencode-entrypoint.sh` → `opencode`; default `CMD ["--help"]` |
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

## Variant: omp (Oh-My-Pi)

[`omp/omp.Dockerfile`](omp/omp.Dockerfile) builds the same hardened box around
[omp](https://omp.sh) (Oh-My-Pi) instead of OpenCode — same digest-pinned
Wolfi base, same non-root uid 10001 with bind-mount uid/gid adaptation, same
bundled tooling. The agent is installed via the official installer
(`curl -fsSL https://omp.sh/install | sh`), pinned to a known-good release
(`OMP_VERSION`), and only the binary is copied into the final image.

```bash
docker build -f omp/omp.Dockerfile -t ai-agent-box:omp .

# Pin a different omp release (bump OMP_VERSION and VERSION together so the
# installed binary and the OCI version label stay in sync)
docker build -f omp/omp.Dockerfile \
  --build-arg OMP_VERSION=v18.1.11 --build-arg VERSION=v18.1.11 \
  -t ai-agent-box:omp .

# Interactive TUI
docker run -it --rm -v "$PWD:/workspace" ai-agent-box:omp

# One-shot prompt
docker run -it --rm -v "$PWD:/workspace" ai-agent-box:omp -p "explain this repo"

# Persist config and sessions across containers (entire directory or agent subfolder)
docker run -it --rm -v "$PWD:/workspace" \
  -v "$HOME/.omp:/home/ai-agent-box/.omp" ai-agent-box:omp

# Or persist only the agent directory:
# docker run -it --rm -v "$PWD:/workspace" \
#   -v "$HOME/.omp/agent:/home/ai-agent-box/.omp/agent" ai-agent-box:omp
```

Differences from the OpenCode image:

| Property | omp image |
|----------|-----------|
| Binary | `/usr/local/bin/omp` (root-owned, 0755, from the official installer) |
| User | `omp`, uid/gid 10001 (arbitrary-uid capable via gid 0; root only needed for the legacy `--user 0` path) |
| Config/data dir | `$HOME/.omp` (`/home/ai-agent-box/.omp`) or `$HOME/.omp/agent` — mount to persist config and sessions |
| Entry | `omp-entrypoint.sh` → `omp`; default `CMD ["--help"]` |
| Server mode | none — omp's entry points are the TUI, one-shot `-p`, RPC, and ACP over stdio, so the image has no `EXPOSE` and the entrypoint injects no `--hostname` |

On native Linux, use the arbitrary-uid recipe (`--user "$(id -u):$(id -g)"
--group-add 0`) exactly as described in [On native Linux (file
ownership)](#on-native-linux-file-ownership); the legacy `--user 0` path
also still works unchanged.

## Using this image as a base

You can layer extra tools (Python, Java, Maven, etc.) on top of this image by
using it as a base in your own Dockerfile:

```dockerfile
FROM ai-agent-box:latest

# The runtime stage ends on `USER opencode` (uid 10001), so switch back to
# root to install packages, then drop privileges again.
USER root

# Pin versions the same way the base image does, so your build stays
# reproducible when Wolfi ships new stable builds.
ARG PYTHON_VERSION=3.13
ARG OPENJDK_VERSION=17

RUN apk add --no-cache \
    python-3.13 \
    openjdk-17 \
    maven-3.9

# Wolfi's JDK packages install under /usr/lib/jvm and do NOT add java to PATH
# or set JAVA_HOME — do both explicitly (Maven needs JAVA_HOME).
ENV JAVA_HOME=/usr/lib/jvm/java-17-openjdk \
    PATH="${JAVA_HOME}/bin:${PATH}"

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
- **Pin package versions for reproducibility.** Wolfi is a rolling
  distribution; an unpinned `apk add maven` gives you whatever is current.
  Either pin explicit versions (`maven=3.9.x-rN`) like the base image's
  `ARG`/`--build-arg` pattern, or accept that rebuilds may drift.
- **Set toolchain env vars explicitly.** `JAVA_HOME` is not set by the Wolfi
  JDK packages; Maven and many build tools need it. Add the JDK's `bin` to
  `PATH` if you want plain `java`/`javac` on the command line.
- **`ENTRYPOINT`/`CMD` are inherited automatically.** Unless you want
  different default behavior, leave them as-is so your derived image still
  runs OpenCode. Override `CMD` (or `ENTRYPOINT`) explicitly if you need to.
- **Preserve ownership under `/home/ai-agent-box`.** Anything you `COPY` or
  create there should be group-owned by gid `0` with group permissions
  mirroring the owner's — e.g. `COPY --chown=opencode:0 --chmod=775 ...`, or
  a `RUN chown -R opencode:0 ... && chmod -R g=u ...` step — matching the
  base image's own arbitrary-uid layout (see [Why gid
  0?](#why-gid-0)). `--chown=opencode:opencode` (the pre-arbitrary-uid
  pattern) still lets the default uid-10001 user write it, but breaks
  writability for anyone using the recommended `--user "$(id -u):$(id -g)"
  --group-add 0` recipe.
- **Give build caches a writable home.** Maven (`.m2`), pip (`.cache/pip`),
  and Gradle (`.gradle`) all write under `$HOME` by default — which is
  `/home/ai-agent-box` and writable, so this works out of the box. To persist
  caches across containers, mount a volume, e.g.
  `-v maven-cache:/home/ai-agent-box/.m2`.
- **Reuse the TLS-intercepting-proxy pattern if needed.** If you're behind a
  corporate MITM proxy, mount an external CA the same way this repo's
  opencode/opencode.Dockerfile does (see [Building behind a TLS-intercepting
  proxy](#building-behind-a-tls-intercepting-proxy)) before your own
  `apk add`/`curl` calls.
- **Expect the image to grow.** Toolchains like a JDK and Maven add real
  weight (often 300–500 MB combined); the "minimal" sizing in this README
  applies to the unmodified base image, not your derived one.
- **Don't reintroduce a path back to root.** The base image deliberately
  ships no setuid/setgid binaries and no `sudo`/`su`/`doas`, so once the
  entrypoint drops privileges via `setpriv` there is nothing in the image
  that can regain root — reinforced by `--no-new-privs` on that `setpriv`
  call (see [Hardening](#hardening-keeping-the-agent-scoped-to-workspace)).
  Installing a package that ships a setuid binary or file capabilities (rare,
  but some `apk add` packages do) as root in your derived `Dockerfile` can
  reopen that path. Check what you installed:
  `docker run --rm --entrypoint sh <your-image> -c "find / -xdev \( -perm -4000 -o -perm -2000 \) -type f 2>/dev/null"`
  should print nothing.

### Worked example: `java/java.Dockerfile`

This repo ships [`java/java.Dockerfile`](java/java.Dockerfile) as a canonical derived
image: it layers BellSoft Liberica JDK 25, Maven Daemon (`mvnd`, which bundles
Maven), and Python 3.13 on top of the base image. It demonstrates the pattern
recommended above: pinned, checksum-verified tarball downloads installed
system-wide for tools Wolfi does not package (SDKMAN was considered and
rejected — it is per-user, writes to `$HOME`, and depends on a live version
catalog, so builds are not reproducible).

Build and verify:

```bash
docker build -f opencode/opencode.Dockerfile -t ai-agent-box:local .
docker build -f java/java.Dockerfile --build-arg BASE_IMAGE=ai-agent-box:local -t ai-agent-box:java .
docker run --rm --entrypoint bash ai-agent-box:java -c 'java -version && mvnd --version && python3 --version'
```

[`java/java.21.Dockerfile`](java/java.21.Dockerfile) is the same worked
example pinned to the latest BellSoft Liberica JDK 21 (LTS) build instead of
25; build it the same way with `-f java/java.21.Dockerfile`.

### Verifying a derived image

After building, confirm your tooling works and the inherited behavior is
intact:

```bash
docker build -t my-agent-box .
docker run --rm my-agent-box --version          # OpenCode still runs
docker run --rm my-agent-box run "run: java -version && mvn -version && python3 --version"
```

The arbitrary-uid recipe, the legacy `--user 0` uid-adaptation path, and
`serve` hostname injection described above all work unchanged in derived
images, since they live in the inherited entrypoint — but see "Preserve
ownership under `/home/ai-agent-box`" above if your derived Dockerfile adds
anything under `$HOME`.

## API keys

OpenCode stores provider credentials under
`~/.local/share/opencode/auth.json` (inside the container:
`/home/ai-agent-box/.local/share/opencode/`). Either persist that directory as a
volume (shown above) or pass keys per-run with `-e`:

```bash
docker run -it --rm -v "$PWD:/workspace" -e ANTHROPIC_API_KEY ai-agent-box:latest
```

Note: on native Linux with the recommended `--user "$(id -u):$(id -g)"
--group-add 0` recipe (or the legacy `--user 0`), the container writes
session/auth files as your own uid, so a persisted directory you create
yourself is already writable. The only case needing a fix is a directory an
*earlier* run created under the plain default (uid `10001`, no `--user`
flag) — fix its ownership once with
`sudo chown -R "$(id -u):$(id -g)" ~/.local/share/opencode`, or the agent
will not be able to write sessions/auth.

## License

Apache-2.0 — see [LICENSE](LICENSE).

## Support my work

<a href="https://ko-fi.com/petromirdzhunev" target="_blank"><img src="https://raw.githubusercontent.com/petromir/petromir/refs/heads/master/assets/kofi-button.svg" alt="Buy Me A Ko-fi" style="height: 45px !important;width: 163px !important;" ></a>
<a href="https://www.buymeacoffee.com/petromirdzhunev" target="_blank"><img src="https://raw.githubusercontent.com/petromir/petromir/refs/heads/master/assets/bmc-button.svg" alt="Buy Me A Coffee" style="height: 45px !important;width: 163px !important;" ></a>
<a href="https://github.com/sponsors/petromir" target="_blank"><img src="https://raw.githubusercontent.com/petromir/petromir/refs/heads/master/assets/github-sponsor-button.svg" alt="GitHub Sponsor" style="height: 45px !important;width: 163px !important;" ></a>
