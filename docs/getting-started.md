# Getting started

Workbench is a [Claude Code](https://claude.com/claude-code) plugin. This guide takes you from install to a working, scaffolded project in a few minutes.

## Prerequisites

- **Claude Code** (the `claude` CLI), authenticated.
- A project directory that is a **git repository** (run `git init` if it isn't — workbench installs a pre-commit guard and reasons about git state).

## 1. Install the plugin

From any Claude Code session:

```text
/plugin marketplace add guuslangelaar0/workbench
/plugin install workbench@workbench
```

`/plugin marketplace add` registers the marketplace (named `workbench`); `/plugin install` enables the plugin. Confirm it loaded:

```text
/plugin list      → workbench, enabled
/help             → /workbench:* commands appear
/agents           → engineer, verifier
```

If commands don't appear immediately, run `/reload-plugins` (or restart Claude Code).

## 2. Set up your project

Start Claude Code in your project directory and run the front door:

```text
/workbench
```

On an unconfigured project this launches the **setup wizard** — a short series of cards. You pick:

1. **A maturity level** — `solo`, `pair`, `crew`, or `fleet`. On an existing repo, workbench **detects a recommendation for you** from your git history (committers, release tags, branches, repo count) and explains why — you just confirm or adjust. Start where your *coordination surface* actually is; you can graduate later. (See [levels.md](levels.md) — read "the struggle each level solves" to place yourself.)
2. **Your operational axes** — verification depth, review, models, graphify, remote control, and so on. Each card offers a *leaner / recommended / better* choice with a plain-language note on the trade-off. (See [configuration.md](configuration.md).)

When you finish, workbench writes `.workbench/config.json` and scaffolds your way of working:

```text
.workbench/config.json        your level + operational choices
.workbench/manifest.json      what was scaffolded, for safe upgrades
CLAUDE.md                     project instructions for every session
.claude/SOUL.md               the quality bar + honesty principles
.claude/tasks/                backlog/ in-development/ verified/ … (stages match your level)
scripts/coord/                multi-session coordination tooling
```

> Already configured? Bare `/workbench` instead shows your current status and the next sensible actions.

## 3. Do some work

```text
/workbench:task "my first capability"   create a task in backlog/
/workbench:mc                           the Mission Control dashboard
/workbench:loop                         run the autonomous teamlead loop
```

`/workbench:loop` is the heart of it: the lead picks the highest-impact unblocked task, dispatches it to an engineer, gates it on verification, and keeps going — checkpointing as it goes so a new session can resume. Bugs it finds file themselves as tasks; new feature ideas are surfaced as suggestions, never silently built.

When you outgrow your level, `/workbench:level up` shows what would change and asks before applying.

---

## Developing workbench itself (local install)

If you're hacking on the plugin, install it from a local checkout instead of the marketplace:

```text
/plugin marketplace add /path/to/workbench
/plugin install workbench@workbench
/reload-plugins
```

`/plugin marketplace add` takes the directory containing `.claude-plugin/marketplace.json`. After editing command/skill/hook files, `/reload-plugins` re-activates them in the current session — though **`SessionStart` hooks only fire on a fresh session**, so exit and relaunch `claude` to see the operating brief.

To smoke-test in a throwaway project:

```sh
mkdir -p ~/wb-smoke && cd ~/wb-smoke && git init && claude
```

…then run `/workbench`, scaffold, exit, relaunch, and confirm the `=== workbench operating brief ===` prints on startup.

Clean up:

To remove scaffolded workbench files from the scratch project, run the project-level uninstaller inside that scratch Claude session:

```text
/workbench:uninstall
```

It defaults to a dry-run. Apply only after reviewing the plan. It uses `.workbench/manifest.json` and preserves user data, `merge` files, `once` files, pre-existing files, and edited files by default.

To remove the Claude Code plugin registration itself, use the plugin commands:

```text
/plugin uninstall workbench@workbench
/plugin marketplace remove workbench
```

These two cleanups are separate: `/workbench:uninstall` affects files scaffolded into a project; `/plugin uninstall` removes the plugin from Claude Code. If skills or commands linger after a reinstall, clear the cache: `rm -rf ~/.claude/plugins/cache`.

### Running the tests

```sh
bash test/all.sh                 # fast, offline — no API, no cost
bash scripts/self-test.sh        # package JSON + shell syntax + publishability + all tests
WB_E2E=1 bash test/e2e/run.sh    # live — loads the real plugin into a headless session (needs auth, costs tokens)
```

See [the test section of the README](../README.md#tests) for what each layer covers.

### Measuring the way of working

Workbench benchmarks itself — see [benchmarking.md](benchmarking.md). The short version:

```sh
scripts/bench.sh                 # free: structural gate + offline conformance
WB_BENCH=1 scripts/bench.sh      # + live conformance (drives the real model; costs tokens)
```
