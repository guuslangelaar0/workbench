---
description: Create/list epics for big multi-part efforts, themes, initiatives, or fleet-level decomposition into related tasks
allowed-tools: ["Bash", "Read", "AskUserQuestion"]
argument-hint: "[\"<title>\"] [--theme <theme>] | list | close <id>"
---

You are the `/workbench:epic` command. Epics group related tasks under one user-facing outcome. They exist at levels whose `decomposition` dial is grouped (pair = light-epics, crew = epics, fleet = themes-epics); a `solo` project uses flat tasks and has no `.claude/epics/` dir.

Use this when the user asks to plan or decompose a big multi-part effort such as "full billing system", "subscriptions/invoices/refunds/webhooks", "launch program", "theme", or "initiative". At fleet level, create the epic first so the plan exists on disk; then create/link child tasks as needed.

Read `$ARGUMENTS` and act:

## `list` (or no argument)

Show the epics and their task rollup by running Mission Control and surfacing its Epics section:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/mc.sh" --no-prod --no-build
```

Report each epic's ID, title, status, and `done/total` child-task count. If there is no `.claude/epics/` dir, tell the user this project's level uses flat tasks (no epics) and that `/workbench:level up` would enable them.

## Create — when `$ARGUMENTS` contains a quoted title

Run the epic scaffolder:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/epic-new.sh" --title "<title>" [--theme "<theme>"] --target "${CLAUDE_PROJECT_DIR}"
```

It allocates the next ID from the **shared** `.claude/tasks/_next-id` (so epic and task IDs never collide), renders the epic into `.claude/epics/`, and bumps the counter. Report the new epic ID and path.

Then tell the user how to attach tasks: create tasks under it with `/workbench:task "<title>" --epic <epic-id>`, or add `**Epic:** <epic-id>` to an existing task's header. The epic's progress (done/total) shows in `/workbench:mc` and `/workbench:epic list`.

An epic's `**Status:**` is `open` until it is closed (see below) — never hand-edit it to `done`.

## Close — when `$ARGUMENTS` starts with `close <id>`

Run the epic closer:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/epic-close.sh" <epic-id> --target "${CLAUDE_PROJECT_DIR}"
```

It scans `.claude/tasks/**/*.md` for every task carrying `**Epic:** <epic-id>`, resolves this project's terminal lifecycle stages from its level (`verified`/`shipped` — whichever the level actually has; `staged`/`release-candidate` are deploy-gated waypoints, not terminal), and only rewrites the epic's `**Status:**` to `done` if every linked task has reached one of those. If any linked task is not yet terminal, it refuses (non-zero exit) and lists exactly which task(s) are blocking and their current stage — this is the same enforcement discipline `task-move.sh`/`verify-gate.sh` already apply to task transitions, now applied to epics too. There is no force override: report the blocking tasks to the user rather than closing anyway.

Report either the closed epic ID, or the blocking task list verbatim so the user knows what still needs to land.

Do not create an epic until you have a title — but if the user asked to create one without a title (or `close` without an id), don't fail or dump usage: run a short wizard — use AskUserQuestion per missing value (offer candidate epic names derived from related backlog task clusters, or open epic IDs for `close`), confirm the assembled command, then run it. If the project is unconfigured, defer to `/workbench:setup` first.
