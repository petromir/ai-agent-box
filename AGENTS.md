# AGENTS.md

Guidance for AI coding agents working in this repository.

## Project

`ai-agent-box` is a Docker image that runs the
[OpenCode](https://opencode.ai) AI coding agent in an isolated, minimal
Wolfi container. It is intentionally tiny:

- `Dockerfile` — two-stage build (installer stage → runtime stage)
- `entrypoint.sh` — start-up script handling uid/gid adaptation for bind
  mounts
- `README.md`, `LICENSE`, `.dockerignore` — docs and build hygiene

There is no application code, no test suite, and no CI pipeline. Changes are
almost always to the Dockerfile or entrypoint script.

## Verify every change

Any Dockerfile or entrypoint change MUST be verified by actually building and
running the image — not just by reading the diff:

```bash
docker build -t ai-agent-box:local .

# 1. Default (non-root) path
docker run --rm ai-agent-box:local --version

# 2. Root/uid-adaptation path: create a repo owned by a non-10001 uid
#    (chown it to 999), then:
docker run --rm --user 0 -v /path/to/repo:/workspace ai-agent-box:local --version
# and confirm "adapting uid/gid..." appears on stderr, and inside the
# container `git -C /workspace status` succeeds.
```

Watch for silent regressions in:

- **Base image** — pinned by digest in both stages; if you bump it, bump BOTH
  stages in the same change.
- **Wolfi package names** — packages that exist in Alpine may not exist in
  Wolfi (e.g. there is no `tar` package; busybox provides it). Verify with
  `docker run --rm cgr.dev/chainguard/wolfi-base:latest@sha256:<digest> sh -c 'apk search <pkg>'`.
- **BusyBox vs GNU tools** — wolfi-base ships BusyBox applets. BusyBox
  `setpriv` lacks `--reuid/--regid`; that's why `util-linux-su` (runuser)
  is installed. Check tool flags before relying on them.
- **opencode install path** — the installer writes to `$HOME/.opencode/bin`;
  the builder stage pins `ENV HOME=/root` so the `COPY --from=builder` path
  is deterministic.

## Conventions

- Keep the image minimal: every added package needs a runtime justification.
  Build-time-only tooling belongs in the builder stage only.
- Never run the final container as root unless the user explicitly passes
  `--user 0` (needed only for uid adaptation on native Linux).
- No secrets in the image or in `ENV`/`ARG` — credentials are mounted or
  passed at `docker run` time.
- OCI label args (`VERSION`, `REVISION`) are for automation; do not hardcode
  build metadata into the Dockerfile.
- Comments in the Dockerfile explain *why*, not *what*; keep them when
  editing.
- After changes, update `README.md` (image details, usage) if behavior,
  packages, or usage patterns changed.

## Environment notes

- The host is macOS + Docker Desktop in this workspace; ownership squashing
  means uid-adaptation bugs will NOT reproduce locally by default. Simulate
  the native-Linux case by `chown`ing a test repo to a foreign uid (e.g.
  999) inside a root container before testing the adaptation path.
- `docker` CLI is available; the daemon may need starting (`open -a Docker`).
