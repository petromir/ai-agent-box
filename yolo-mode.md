# YOLO mode: running the agent unattended without it going wild

How to run OpenCode in this image in full auto-mode (no human approvals)
while keeping hard guardrails against infinite loops, runaway token spend,
and destructive actions.

## The mental model: `ask` does not exist in auto-mode

OpenCode permissions resolve to one of three actions:

| Rule    | Interactive TUI        | `--auto` mode (`opencode --auto` or `opencode run --auto`) |
| ------- | ---------------------- | ---------------------------------------------------------- |
| `allow` | runs                   | runs                                                       |
| `ask`   | pauses, prompts a human | **auto-approved — runs anyway**                            |
| `deny`  | blocked; agent must route around it | blocked; agent must route around it |

`--auto` approves every permission request that is not explicitly denied.
Consequences:

- **`ask` rules are useless in auto-mode.** They protect you interactively
  and do nothing unattended.
- **The binary choice is `allow` vs `deny`.** Anything you do not want the
  agent to do must be `deny`.
- There is a dedicated `question` permission for the agent asking the user
  mid-execution. `"question": "deny"` is the "exit instead of asking"
  behavior: the question tool call fails, and with nobody to answer, the
  turn simply ends.

## Layer 1: OpenCode config (behavioral walls)

Ship an `opencode.json` in the image (or mount one at runtime) along these
lines:

```jsonc
{
  "$schema": "https://opencode.ai/config.json",

  // Hard cap on agentic steps per turn. THE infinite-loop control:
  // after N tool-call round-trips the turn forcibly ends, no matter
  // what the agent wants to do next.
  "agent": {
    "build": { "steps": 50 }
  },

  "permission": {
    // Never pause for a human; the turn just ends instead.
    "question": "deny",

    // Stay inside /workspace.
    "external_directory": "deny",

    // Optional: no uncontrolled egress / web prompt injection.
    "webfetch": "deny",
    "websearch": "deny",

    // doom_loop fires when the same tool call repeats 3x with identical
    // input. It defaults to "ask" — which auto-mode would APPROVE,
    // defeating the protection. Must be "deny" to work unattended.
    "doom_loop": "deny",

    "bash": {
      // In auto-mode you must allow bash broadly to be useful;
      // carve out hard walls for the destructive cases.
      "*": "allow",
      "rm -rf *": "deny",
      "git push *": "deny",
      "git commit *": "deny"
    }
  }
}
```

Notes:

- `deny` is a hard wall the agent cannot cross — the tool call returns an
  error and the agent must find another way or stop.
- Keep the `bash` deny list focused; pattern matching is simple wildcards
  (`*` any chars, `?` one char), last matching rule wins.

## Layer 2: Loop and cost caps

Config-level breakers for runaway sessions:

- **`agent.<name>.steps: N`** — the primary anti-loop knob (see above).
- **`doom_loop: deny`** — kills the classic "identical call repeated"
  failure mode (see above).
- **`OPENCODE_EXPERIMENTAL_OUTPUT_TOKEN_MAX`** — env var capping output
  tokens per LLM response. Set it in the entrypoint, e.g.
  `export OPENCODE_EXPERIMENTAL_OUTPUT_TOKEN_MAX=8192`.
- **`OPENCODE_DISABLE_AUTOCOMPACT`** — decide deliberately: with
  auto-compaction off, a very long session errors out on context limits
  instead of compacting silently forever. Crude, but a real cost cap.
- **`OPENCODE_PERMISSION`** — inline JSON permissions via env var; useful
  to enforce policy at `docker run` time without mounting a config file.

## Layer 3: Container walls (unbypassable)

Config lives in the environment the agent can potentially modify; the
container boundary does not. These work even if every config guard fails:

1. **Wall-clock timeout** — wrap the agent in the entrypoint (BusyBox
   `timeout` is already in the image):

   ```sh
   exec timeout -s KILL "${TIMEOUT:-1800}" opencode "$@"
   ```

2. **Resource and network limits at `docker run`:**

   ```bash
   docker run --rm --memory 2g --cpus 2 \
     -v "$PWD:/workspace" \
     ai-agent-box run --auto "task description"
   ```

   - `--network none` cuts token spend at the source (no API calls) — only
     viable with a local provider; otherwise use an egress allowlist proxy
     permitting only the provider API host.
   - `-v repo:/workspace:ro` for analysis-only tasks makes `edit` moot.

3. **Provider-side budget** — the only *true* token-budget enforcement is
   at the provider (spend limits, rate-limited keys). Mount a dedicated
   low-limit API key at runtime, consistent with the "no secrets in the
   image" rule:

   ```bash
   docker run --rm -e ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY_LIMITED" ...
   ```

## Putting it together

```bash
docker run --rm \
  --memory 2g --cpus 2 \
  -e OPENCODE_PERMISSION='{"question":"deny","external_directory":"deny","doom_loop":"deny"}' \
  -e OPENCODE_EXPERIMENTAL_OUTPUT_TOKEN_MAX=8192 \
  -v "$PWD:/workspace" \
  ai-agent-box run --auto "Fix the failing tests in src/"
```

Three independent circuit breakers, in order of precision:

1. **`deny` rules** — behavioral walls: what the agent may never do.
2. **`steps` + `doom_loop: deny`** — loop breakers: when it must stop.
3. **`timeout` + network/key budget** — dumb physical walls: when
   everything above fails.

## Caveats

- Verify `doom_loop`'s default and the exact location of the `steps`
  setting (`agent.<name>.steps`) against the pinned `OPENCODE_VERSION` in
  the Dockerfile — these have moved between releases.
- `deny` rules in a mounted `opencode.json` are only as strong as the
  agent's inability to edit that file. Mount it read-only
  (`-v ./opencode.json:/home/ai-agent-box/.config/opencode/opencode.json:ro`)
  if you do not trust the agent around its own config.
- `OPENCODE_EXPERIMENTAL_*` variables are experimental and may change or
  be removed between OpenCode releases; re-check them on version bumps.
