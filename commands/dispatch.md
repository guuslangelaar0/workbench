---
description: Dispatch a specific unblocked backlog task by id to an engineer lane — Claude by default, or Codex via --engine codex — after checking claims, dependencies, and in-review pressure
allowed-tools: ["Bash", "Read", "Task", "Agent", "TodoWrite", "AskUserQuestion"]
argument-hint: "<id> [--engine claude|codex] [--worktree [name]|--shared] [--background|--wait] [--reconcile --fresh|--resume --model <model|spark> --effort <level> (codex only)] [lane/repo]"
---

`dispatch` is the generic front door for "assign this task to an engineer" — it does not care which engine does the work. Follow the `orchestration` skill — **you are the lead; you do not write the code yourself.**

1. Parse `$ARGUMENTS` for an `--engine <claude|codex>` flag.
   - No `--engine` flag, or `--engine claude`: the engine is **Claude** — this is the default and is exactly what `/workbench:dispatch <id>` has always done. Nothing about this path changes: same flags, same claim/move-to-in-development step, same lane spawn, same gate.
   - `--engine codex`: the engine is **Codex**.
   Strip `--engine <value>` from the arguments; forward everything else (`<id>`, lane/repo hint, and any remaining flags) unchanged to the resolved engine's command below.
2. Route to the engine-specific command and follow **every step it documents**, verbatim, with the forwarded arguments:
   - **Claude (default):** follow `commands/claude-engineer.md` — it claims the task via `wb-coord`, moves it to `in-development` (`task-move.sh`), resolves the model via the `models` skill, and spawns the `engineer` Task-tool lane (foreground, `--worktree`, `--background`/`--wait`, or `--shared`).
   - **Codex (`--engine codex`):** follow `commands/codex-engineer.md` — it claims the task via `wb-coord`, moves it to `in-development`, starts the disk lane lease and Workbench job record, and invokes the `codex:codex-rescue` subagent through the `Agent` tool. This also covers `--reconcile`, `--fresh`/`--resume`, `--model`, and `--effort`.
3. Never claim the task is done here — dispatch only starts the work, regardless of engine.

If invoked without a task `<id>` (or an ambiguous one), don't fail or dump usage — run a short wizard: get unblocked candidates from `bash "${CLAUDE_PLUGIN_ROOT}/scripts/deps.sh" ready --target "${CLAUDE_PROJECT_DIR}"`, use AskUserQuestion to pick the task (and the engine, if the user hinted at Codex), confirm the assembled `/workbench:dispatch <id> [--engine …]`, then run it.

`/workbench:claude-engineer <id>` and `/workbench:codex-engineer <id>` remain independently callable when the user wants to name the engine directly; `/workbench:dispatch` is the engine-agnostic entry point that defaults to Claude and routes to whichever engine `--engine` (or the equivalent direct command) selects.
