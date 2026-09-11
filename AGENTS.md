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
- `java/java.25.Dockerfile` — worked example of a derived image (see "Extending
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
docker build -f opencode/opencode.Dockerfile -t ai-agent-box:1.18.30 .

# 1. Default (non-root) path
docker run --rm ai-agent-box:1.18.30 --version

# 2. Root/uid-adaptation path: create a repo owned by a non-10001 uid
#    (chown it to 999), then:
docker run --rm --user 0 -v /path/to/repo:/workspace ai-agent-box:1.18.30 --version
# and confirm "adapting uid/gid..." appears on stderr, and inside the
# container `git -C /workspace status` succeeds and the adapted user can
# write to ~/.config/opencode (e.g. `touch` a file there as the user).

# 3. Serve path: the entrypoint injects --hostname 0.0.0.0 for the `serve`
#    subcommand so a published port reaches the server. Confirm health, and
#    that an explicit --hostname override is honored.
docker run --rm -d -p 4096:4096 --name opencode-server ai-agent-box:1.18.30 serve
curl -s http://localhost:4096/global/health   # {"healthy":true,"version":"..."}
docker rm -f opencode-server   # opencode serve ignores SIGTERM/SIGINT; rm -f force-kills
# Override must bind loopback (unreachable from host via -p):
docker run --rm -d -p 4097:4097 --name oc-lb ai-agent-box:1.18.30 serve --port 4097 --hostname 127.0.0.1
curl -s --max-time 3 http://localhost:4097/global/health || echo unreachable-as-expected
docker rm -f oc-lb

# 4. Arbitrary-uid path (recommended over --user 0; see
#    PLAN-arbitrary-uid-home-layout.md and README "On native Linux"): an
#    arbitrary uid with gid 0 can write the home tree and use git with NO
#    uid/gid rewrite and NO root at any point.
docker run --rm --user 999:0 ai-agent-box:1.18.30 --version
# same uid WITHOUT gid 0 in any form must NOT be able to write:
docker run --rm --user 999:999 --entrypoint sh ai-agent-box:1.18.30 \
  -c 'touch "$HOME/.config/opencode/.probe" && echo OK || echo FAIL-as-expected'
# the zero-`--user` default must stay byte-for-byte unchanged (uid=10001 gid=10001):
docker run --rm --entrypoint sh ai-agent-box:1.18.30 -c 'id -u; id -g'
```

The omp variant carries the same obligation (there is no serve check — omp has
no HTTP server; its entry points are the TUI, one-shot `-p`, RPC, and ACP over
stdio):

```bash
docker build -f omp/omp.Dockerfile -t ai-agent-box:v18.1.17 .

# 1. Default (non-root) path
docker run --rm ai-agent-box:v18.1.17 --version   # omp/<version>

# 2. Root/uid-adaptation path: same foreign-uid setup as above, then:
docker run --rm --user 0 -v /path/to/repo:/workspace ai-agent-box:v18.1.17 --version
# and confirm "adapting uid/gid..." appears on stderr and the adapted user
# can write to ~/.omp and ~/.omp/agent (e.g. `touch` a file there as the user).

# 3. Arbitrary-uid path (same rationale as opencode above):
docker run --rm --user 999:0 ai-agent-box:v18.1.17 --version
docker run --rm --user 999:999 --entrypoint sh ai-agent-box:v18.1.17 \
  -c 'touch "$HOME/.omp/.probe" && echo OK || echo FAIL-as-expected'
docker run --rm --entrypoint sh ai-agent-box:v18.1.17 -c 'id -u; id -g'
```

CI runs the same suite for you: `.github/workflows/docker.yml` executes
`tests/run-tests.sh` on every pull request and push to `master`, and on
master it additionally publishes all three images to Docker Hub (see
README.md "Continuous integration"). A change that fails the suite locally
will fail CI identically — local verification stays mandatory anyway,
because CI cannot tell you *why* the entrypoint broke.

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
- **shellcheck pin** — Wolfi has **no** `shellcheck` package (`apk search
  shellcheck` is empty; Wolfi ships no GHC toolchain) and Alpine packages
  cannot be mixed into a Wolfi image, so both Dockerfiles install upstream's
  statically linked release `.tar.gz` with a pinned version plus pinned
  per-architecture SHA256 (`SHELLCHECK_VERSION`,
  `SHELLCHECK_SHA256_AMD64`/`SHELLCHECK_SHA256_ARM64`), in the builder stage
  and `COPY --from=builder` like `fff-mcp`. Those `.tar.gz` assets exist only
  from v0.11.0 (older tags publish `.tar.xz` only, and wolfi-base ships no xz
  tool — BusyBox `unxz` at best; a Wolfi `xz` package exists but is not worth
  an extra builder dependency for one tarball). Keep the version and both
  SHA256s in sync across the two Dockerfiles and the `shellcheck_version`
  constant in `tests/run-tests.sh`. Beware when a repo script mentions it in a
  comment: a line starting `# shellcheck ` is parsed as a directive by the tool
  itself (SC1072/SC1073 on the repo's own scripts).
- **copyleft notices must ship** — the runtime stage copies ShellCheck's
  `LICENSE.txt` plus a Corresponding-Source pointer (`SOURCE.txt`) to
  `/usr/share/doc/shellcheck/`, Wolfi's own convention for package licenses
  (`apk info -L jq` -> `usr/share/doc/jq/COPYING`). Pre-create that directory in
  its own `RUN mkdir -m 0755`: `COPY --chmod` applies to directories it creates
  too, so a `--chmod=644` copy that has to make the parent dir leaves a
  non-traversable `0444` directory the non-root user cannot read. Any GPL/LGPL
  binary added to the image needs the same treatment (the Wolfi packages
  already do this for themselves — `bash`, `diffutils`, `busybox` are GPL too).
  It changes nothing about this repo's own files: separate programs in one
  filesystem are mere aggregation (GPLv3 §5), so
  Apache-2.0 stays Apache-2.0; only ShellCheck itself carries GPLv3 duties, and
  only on distribution. Keep ShellCheck a subprocess — linking its Haskell
  library would make the linking program a derivative work.
- **opencode install path** — the installer writes to `$HOME/.opencode/bin`;
  the builder stage pins `ENV HOME=/root` so the `COPY --from=builder` path
  is deterministic.
- **Home/config ownership** — the runtime home is `/home/ai-agent-box`
  (keep `adduser -h`, `mkdir`/`chown`, `ENV HOME` in the opencode/opencode.Dockerfile and
  `home_dir` in the entrypoint in sync). The image owns the whole `$HOME`
  tree (and `/workspace`) as `<user>:0` with `chmod g=u` + setgid directories
  (the "arbitrary-uid" pattern — see PLAN-arbitrary-uid-home-layout.md): this
  must cover *all* of `$HOME`, not just `.config`/`.local`, since the agent
  creates other dot-dirs on demand (e.g. `~/.cache`) that must be creatable
  by an arbitrary uid too. After `--user 0` uid adaptation the entrypoint
  must still chown `.config`/`.local` (non-recursively) for the legacy path —
  but must NEVER chown them when they are bind mounts, to avoid altering
  host file ownership.
- **The zero-`--user` default must stay byte-for-byte unchanged** — always
  uid=10001 gid=10001, home tree writable via direct ownership, not via the
  gid-0 mechanism. Any change to the Dockerfile's ownership/permission step
  or the entrypoint must re-verify this (see "Verify every change" #4 above).
- **`/etc/passwd`/`/etc/group` are group-writable by design** (`chmod g=u`,
  both Dockerfiles), paired with `ensure_passwd_entry` in both entrypoints:
  an arbitrary uid with no built-in passwd entry breaks `ssh`/`whoami`
  otherwise (openssh-client refuses to run as an unrecognized uid). The
  append step is non-fatal (logs and continues) so a read-only `/etc` (e.g.
  `--read-only` without a writable overlay) degrades gracefully instead of
  aborting the container.
- **`git config --system --add safe.directory '*'` is baked at build time**
  in both Dockerfiles — this is what lets the non-root/arbitrary-uid path
  skip any runtime git config entirely. Keep the `'*'` scope (not narrowed to
  `/workspace`) so nested repos under `/workspace` are covered too; the
  legacy `--user 0` root branch still additionally runs a runtime
  `git config --system --add safe.directory "${mount_dir}"` for defense in
  depth — harmless duplication, not a bug.
- **omp installer flags** — `omp/omp.Dockerfile` pins the release via
  `sh -s -- --binary --ref ${OMP_VERSION}`; `--ref` WITHOUT `--binary`
  switches the installer to a from-source install via bun (slow,
  non-reproducible). Keep `OMP_VERSION` and the `VERSION` label arg in sync,
  same as `OPENCODE_VERSION`/`VERSION` above.
- **omp has no serve mode** — never add `--hostname` injection or `EXPOSE` to
  the omp variant; injecting a flag into `omp acp` breaks the stdio protocol.
- **omp home ownership** — the omp image owns `~/.omp` and `~/.omp/agent` as
  `omp:0` with `chmod g=u` + setgid directories, the same arbitrary-uid
  pattern as the opencode dirs above. After `--user 0` uid adaptation
  `omp/omp-entrypoint.sh` must still chown both (non-recursively) for the
  legacy path, and NEVER when they are bind mounts.
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
- **CI workflow parses the Dockerfile pins** — the publish job in
  `.github/workflows/docker.yml` extracts registry tags with
  `sed -n 's/^ARG OPENCODE_VERSION=//p'` (same for `OMP_VERSION` and
  `LIBERICA_VERSION`): those ARG declarations must stay line-initial,
  single-line, and keep their names, or publishing fails closed. A new image
  variant needs a matching publish step there (and its base-image dependency
  ordered after the base's push, like the java step). Third-party actions are
  pinned to full commit SHAs matching this repo's pinning conventions — bump
  the SHA and its trailing `# vX.Y.Z` comment together.

## Conventions

- Keep the image minimal: every added package needs a runtime justification.
  Build-time-only tooling belongs in the builder stage only.
- Never run the final container as root. Native-Linux users with a foreign
  host uid should prefer `--user "$(id -u):$(id -g)" --group-add 0` (the
  arbitrary-uid recipe — no root involved at all); `--user 0` still works as
  a legacy fallback (briefly root, only for the entrypoint's own uid/gid
  rewrite) but is no longer the recommended path — see README "On native
  Linux (file ownership)".
- No secrets in the image or in `ENV`/`ARG` — credentials are mounted or
  passed at `docker run` time. This applies to any token or secret env
  variable a skill/tool needs (e.g. `GITHUB_TOKEN`), not just model provider
  API keys — use `-e VAR` (forwarding an already-exported shell variable) or
  `--env-file` with a plain `KEY=VALUE` file; never `source ~/.bashrc` into
  the container. See README.md "Passing tokens and secrets for skills/tools".
- OCI label args (`VERSION`, `REVISION`) are for automation; do not hardcode
  build metadata into the opencode/opencode.Dockerfile.
- Do not put a hardcoded image **size** figure back into `README.md`'s "Image
  details" table — it goes stale with every agent release (it did twice). The
  row points at "How big is it?", which publishes the `docker images` /
  `docker history` commands instead. Keep it that way; a dated snapshot inside
  that section must say which arch and release it measured.
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
  `chown`ed to `opencode:0` with `chmod g=u` (matching this repo's own
  arbitrary-uid pattern — see "Home/config ownership" above), not
  `opencode:opencode`, or the arbitrary-uid recipe can't write it even
  though the default uid-10001 user still can.
- This is a documentation/consumer-workflow concern, not a code change here;
  keep the "Using this image as a base" section in README.md in sync if the
  final `USER`, `HOME`, or package-manager story in the
  `opencode/opencode.Dockerfile` changes.
- `java/java.25.Dockerfile` is the in-repo worked example of this pattern (Liberica
  JDK 25, mvnd, Python 3.13 via pinned, checksum-verified downloads — NOT
  SDKMAN, which is per-user and non-reproducible). Verify it after any base
  change: `docker build -f opencode/opencode.Dockerfile -t ai-agent-box:1.18.30 . && docker build -f
  java/java.25.Dockerfile --build-arg BASE_IMAGE=ai-agent-box:1.18.30 -t ai-agent-box:java .`
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
