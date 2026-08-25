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
# Latest OpenCode release (default)
docker build -t ai-agent-box:latest .

# Pinned OpenCode release
docker build --build-arg OPENCODE_VERSION=1.18.23 -t ai-agent-box:1.18.23 .

# OCI label metadata
docker build --build-arg VERSION=1.18.23 --build-arg REVISION="$(git rev-parse --short HEAD)" .
```

## Run

### Interactive TUI

```bash
cd your-project
docker run -it --rm \
  -v "$PWD:/workspace" \
  -v "$HOME/.local/share/opencode:/home/opencode/.local/share/opencode" \
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
  -v "$HOME/.config/opencode:/home/opencode/.config/opencode" \
  ai-agent-box:latest

# Individual config file only
docker run -it --rm \
  -v "$PWD:/workspace" \
  -v "$HOME/.config/opencode/opencode.json:/home/opencode/.config/opencode/opencode.json" \
  ai-agent-box:latest

# Custom skills directory
docker run -it --rm \
  -v "$PWD:/workspace" \
  -v "$HOME/.config/opencode/skills:/home/opencode/.config/opencode/skills" \
  ai-agent-box:latest
```

Container paths:
| Host path | Container mount | Purpose |
|-----------|----------------|---------|
| `~/.config/opencode/` | `/home/opencode/.config/opencode/` | Full config: `opencode.json`, agents, skills |
| `~/.config/opencode/opencode.json` | `/home/opencode/.config/opencode/opencode.json` | Main configuration file |
| `~/.config/opencode/agents/` | `/home/opencode/.config/opencode/agents/` | Custom agent definitions |
| `~/.config/opencode/skills/` | `/home/opencode/.config/opencode/skills/` | Custom skill definitions |

The entrypoint creates `~/.config/opencode` on first run if it does not exist.
When you bind-mount a directory over it, the mount replaces the container
directory — your host files are used as-is.

### Non-interactive

```bash
docker run -it --rm -v "$PWD:/workspace" ai-agent-box:latest run "explain this repo"
docker run --rm -v "$PWD:/workspace" ai-agent-box:latest --version
```

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
| Data dirs | `$HOME=/home/opencode` (writable), `WORKDIR=/workspace` |
| Size | ~243 MB |
| Entry | `entrypoint.sh` → `opencode`; default `CMD ["--help"]` |

Runtime packages: `bash`, `curl`, `git`, `openssh-client`, `util-linux-su`
(for `runuser`). The build stage runs the official installer
(`curl -fsSL https://opencode.ai/install | bash`) and copies only the binary
into the final image — no install toolchain in the runtime layer.

## API keys

OpenCode stores provider credentials under
`~/.local/share/opencode/auth.json` (inside the container:
`/home/opencode/.local/share/opencode/`). Either persist that directory as a
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
