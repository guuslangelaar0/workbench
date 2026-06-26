# Contributing to workbench

Thanks for your interest. Workbench is a Claude Code plugin built from plain markdown, shell, and JSON — no build step, no runtime dependencies.

## Ground rules

- **Tests must pass.** Run `bash test/all.sh` before opening a PR; it's fast and offline.
- **No secrets, ever.** Don't commit `.env` files, tokens, keys, or credentials. The scaffolded projects install a pre-commit secret guard; this repo expects the same hygiene.
- **The scaffold path stays dependency-free.** `scripts/init.sh` and `scripts/lib.sh` (the code that runs on a user's machine during scaffolding) must use only POSIX-ish shell — **no `jq`, no `python`**. Dev tooling and tests *may* use `python3`.
- **Match the surrounding style.** Commands and skills are markdown with a specific voice; scripts are pure bash. Read a neighbour before adding a file.

## Project layout

```text
.claude-plugin/   plugin.json + marketplace.json
commands/         /workbench:* slash commands (markdown the model executes)
skills/           operating disciplines (levels, orchestration, continuity, …)
agents/           engineer + verifier subagent definitions
hooks/            SessionStart / PreCompact / PostToolUse / PreToolUse / Notification
scripts/          the CLI (init, task-new, task-move, mc, levels, loop-policy, graduate, drift)
templates/        what gets scaffolded into a project (minimal | full)
test/             all.sh (offline suites) + e2e/ (live-plugin)
docs/             user-facing documentation
```

## Testing

Two layers:

```sh
bash test/all.sh                 # offline unit + integration suites — no API, no cost
WB_E2E=1 bash test/e2e/run.sh    # live: loads the real plugin into a headless `claude` session
```

- **`test/all.sh`** runs the per-script suites plus `dogfood.test.sh` (a full model-free scaffold → tasks → lifecycle → dashboard run). Add a `*.test.sh` and wire it into `test/all.sh` when you add a script or behavior.
- **`test/e2e/run.sh`** loads the actual plugin via `claude -p --plugin-dir` and asserts on what the real model + commands + hooks do. It's gated behind `WB_E2E=1` because it needs an authenticated `claude` CLI and costs tokens. Add a scenario when you add a command whose end-to-end behavior matters.

A change that touches a script should come with a test that would have failed before it. A change that touches a command's behavior should ideally come with an e2e scenario.

## Pull requests

1. Branch from `main`.
2. Make the change + the test that proves it.
3. `bash test/all.sh` green.
4. Open the PR with a clear description of the behavior change.

## Documentation

If you change a command, dial, lifecycle stage, or config field, update the relevant doc under `docs/` and the `README.md` table in the same PR. Stale docs are bugs.
