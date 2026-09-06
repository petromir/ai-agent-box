# AGENTS.md

Guidance for AI coding agents working in this repository.

## Project

`ai-agent-box` is a Docker image that runs the
[OpenCode](https://opencode.ai) AI coding agent in an isolated, minimal
Wolfi container. It is intentionally tiny:

- `opencode/opencode.Dockerfile` — two-stage build (installer stage → runtime stage)
- `opencode/opencode-entrypoint.sh` — start-up script handling uid/gid adaptation for bind
  mounts
- `omp/omp.Dockerfile`, `omp/omp-entrypoint.sh` — parallel variant of the same
  box running the [omp](https://omp.sh) (Oh-My-Pi) agent instead of OpenCode
- `java/java.Dockerfile` — worked example of a derived image (see "Extending
  this image as a base")
- `README.md`, `LICENSE`, `.dockerignore` — docs and build hygiene

There is no application code, no test suite, and no CI pipeline. Changes are
almost always to the opencode/opencode.Dockerfile or entrypoint script.

## Verify every change

Any opencode/opencode.Dockerfile or entrypoint change MUST be verified by actually building and
running the image — not just by reading the diff. `tests/run-tests.sh` automates
all checks below (`--skip-build` reuses built images, `--only opencode,omp,java`
runs a subset); prefer it over running the commands by hand:

```bash
docker build -f opencode/opencode.Dockerfile -t ai-agent-box:local .

# 1. Default (non-root) path
docker run --rm ai-agent-box:local --version

# 2. Root/uid-adaptation path: create a repo owned by a non-10001 uid
#    (chown it to 999), then:
docker run --rm --user 0 -v /path/to/repo:/workspace ai-agent-box:local --version
# and confirm "adapting uid/gid..." appears on stderr, and inside the
# container `git -C /workspace status` succeeds and the adapted user can
# write to ~/.config/opencode (e.g. `touch` a file there as the user).

# 3. Serve path: the entrypoint injects --hostname 0.0.0.0 for the `serve`
#    subcommand so a published port reaches the server. Confirm health, and
#    that an explicit --hostname override is honored.
docker run --rm -d -p 4096:4096 --name opencode-server ai-agent-box:local serve
curl -s http://localhost:4096/global/health   # {"healthy":true,"version":"..."}
docker rm -f opencode-server   # opencode serve ignores SIGTERM/SIGINT; rm -f force-kills
# Override must bind loopback (unreachable from host via -p):
docker run --rm -d -p 4097:4097 --name oc-lb ai-agent-box:local serve --port 4097 --hostname 127.0.0.1
curl -s --max-time 3 http://localhost:4097/global/health || echo unreachable-as-expected
docker rm -f oc-lb
```

The omp variant carries the same obligation (there is no serve check — omp has
no HTTP server; its entry points are the TUI, one-shot `-p`, RPC, and ACP over
stdio):

```bash
docker build -f omp/omp.Dockerfile -t ai-agent-box:omp-local .

# 1. Default (non-root) path
docker run --rm ai-agent-box:omp-local --version   # omp/<version>

# 2. Root/uid-adaptation path: same foreign-uid setup as above, then:
docker run --rm --user 0 -v /path/to/repo:/workspace ai-agent-box:omp-local --version
# and confirm "adapting uid/gid..." appears on stderr and the adapted user
# can write to ~/.omp and ~/.omp/agent (e.g. `touch` a file there as the user).
```

Watch for silent regressions in:

- **Base image** — pinned by digest in both stages; if you bump it, bump BOTH
  stages in the same change.
- **Wolfi package names** — packages that exist in Alpine may not exist in
  Wolfi (e.g. there is no `tar` package; busybox provides it). Verify with
  `docker run --rm cgr.dev/chainguard/wolfi-base:latest@sha256:<digest> sh -c 'apk search <pkg>'`.
- **BusyBox vs GNU tools** — wolfi-base ships BusyBox applets. BusyBox
  `setpriv` lacks `--reuid/--regid`; that's why the `setpriv` **package**
  (util-linux's setpriv, a separate binary from the BusyBox applet of the
  same name) is installed and used to drop privileges. Check tool flags
  before relying on them.
- **opencode install path** — the installer writes to `$HOME/.opencode/bin`;
  the builder stage pins `ENV HOME=/root` so the `COPY --from=builder` path
  is deterministic.
- **Home/config ownership** — the runtime home is `/home/ai-agent-box`
  (keep `adduser -h`, `mkdir`/`chown`, `ENV HOME` in the opencode/opencode.Dockerfile and
  `home_dir` in the entrypoint in sync). The image pre-creates
  `~/.config/opencode` and `~/.local/share/opencode` owned by uid 10001;
  after uid adaptation the entrypoint must chown both (non-recursively) or
  the adapted user cannot write config/sessions — but must NEVER chown them
  when they are bind mounts, to avoid altering host file ownership.
- **omp installer flags** — `omp/omp.Dockerfile` pins the release via
  `sh -s -- --binary --ref ${OMP_VERSION}`; `--ref` WITHOUT `--binary`
  switches the installer to a from-source install via bun (slow,
  non-reproducible). Keep `OMP_VERSION` and the `VERSION` label arg in sync,
  same as `OPENCODE_VERSION`/`VERSION` above.
- **omp has no serve mode** — never add `--hostname` injection or `EXPOSE` to
  the omp variant; injecting a flag into `omp acp` breaks the stdio protocol.
- **omp home ownership** — the omp image pre-creates `~/.omp` and
  `~/.omp/agent` owned by uid 10001; after uid adaptation
  `omp/omp-entrypoint.sh` must chown both (non-recursively) and NEVER when
  they are bind mounts — same rule as the opencode dirs above.
- **TLS-intercepting build networks** — if `apk add`/`curl` fail in a `RUN`
  step with `certificate verify failed`, that's a local/corporate proxy MITM
  issue, not a Dockerfile bug (confirm by checking `docker info` for a
  configured HTTP/HTTPS proxy). Both stages already have a
  `RUN --mount=type=secret,id=external_ca,required=false` step before their
  first network call, documented in README.md's "Building behind a
  TLS-intercepting proxy" — pass `--secret id=external_ca,src=<ca-bundle.pem>`
  to trust a local proxy CA for that build only. Never "fix" this by baking a
  CA into a `COPY`/`ARG` instead — that would ship a private, meaningless (or
  actively risky) root CA to everyone who pulls the published image.

## Conventions

- Keep the image minimal: every added package needs a runtime justification.
  Build-time-only tooling belongs in the builder stage only.
- Never run the final container as root unless the user explicitly passes
  `--user 0` (needed only for uid adaptation on native Linux).
- No secrets in the image or in `ENV`/`ARG` — credentials are mounted or
  passed at `docker run` time.
- OCI label args (`VERSION`, `REVISION`) are for automation; do not hardcode
  build metadata into the opencode/opencode.Dockerfile.
- Comments in the opencode/opencode.Dockerfile explain *why*, not *what*; keep them when
  editing.
- After changes, update `README.md` (image details, usage) if behavior,
  packages, or usage patterns changed.

## Extending this image as a base

Users may build their own Dockerfile with `FROM ai-agent-box:<tag-or-digest>`
to layer extra tools (e.g. Python, Java, Maven) on top. Keep this workflow
supported when changing the runtime stage:

- The runtime stage ends on `USER opencode` (uid 10001), a non-root user.
  Derived Dockerfiles must `USER root` before any `apk add`, then `USER
  opencode` again afterward — do not remove or reorder the final `USER
  opencode` in this repo's `opencode/opencode.Dockerfile` to "help" that use case; it stays
  non-root by default per the Conventions below.
- Wolfi package names may differ from Alpine's; derived-image authors must
  verify names the same way this repo does (see "Wolfi package names" above).
- Toolchains installed on top may need env vars the Wolfi packages do not
  set (e.g. `JAVA_HOME` for Maven). The README's derived-image example sets
  these; keep it accurate if the base image's paths or layout change.
- Language build caches (Maven `.m2`, pip `.cache/pip`, Gradle `.gradle`)
  land in `$HOME` — keep `$HOME=/home/ai-agent-box` writable and owned by
  the runtime user so these work without extra setup.
- `ENTRYPOINT`/`CMD` are inherited by derived images automatically; do not
  add logic to this repo's `opencode/opencode-entrypoint.sh` that assumes it is always the
  final image (e.g. do not hardcode a package list check) — a derived image
  adding tools must not break the base entrypoint's uid-adaptation or serve
  hostname-injection behavior.
- Anything a derived Dockerfile adds under `/home/ai-agent-box` must be
  `chown`ed to `opencode:opencode` (uid/gid 10001), matching this repo's
  own pattern, or the runtime user won't be able to write to it.
- This is a documentation/consumer-workflow concern, not a code change here;
  keep the "Using this image as a base" section in README.md in sync if the
  final `USER`, `HOME`, or package-manager story in the
  `opencode/opencode.Dockerfile` changes.
- `java/java.Dockerfile` is the in-repo worked example of this pattern (Liberica
  JDK 25, mvnd, Python 3.13 via pinned, checksum-verified downloads — NOT
  SDKMAN, which is per-user and non-reproducible). Verify it after any base
  change: `docker build -f opencode/opencode.Dockerfile -t ai-agent-box:local . && docker build -f
  java/java.Dockerfile --build-arg BASE_IMAGE=ai-agent-box:local -t ai-agent-box:java .`
  and run the same default/uid-adaptation/serve checks against
  `ai-agent-box:java`. When bumping its pinned tool versions, refresh the
  checksums: Liberica SHA1s via `api.bell-sw.com/v1/liberica/releases`
  (use `arch=x86`/`arch=arm`), mvnd SHA256s from the `.sha256` files next to
  the tarballs on archive.apache.org.

## Environment notes

- The host is macOS + Docker Desktop in this workspace; ownership squashing
  means uid-adaptation bugs will NOT reproduce locally by default. Simulate
  the native-Linux case by `chown`ing a test repo to a foreign uid (e.g.
  999) inside a root container before testing the adaptation path.
- `docker` CLI is available; the daemon may need starting (`open -a Docker`).
