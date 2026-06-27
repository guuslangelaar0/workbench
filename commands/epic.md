---
description: Create or list epics — groups of related tasks (pair level and up)
allowed-tools: ["Bash", "Read"]
argument-hint: "[\"<title>\"] [--theme <theme>] | list"
---

You are the `/workbench:epic` command. Epics group related tasks under one user-facing outcome. They exist at levels whose `decomposition` dial is grouped (pair = light-epics, crew = epics, fleet = themes-epics); a `solo` project uses flat tasks and has no `.claude/epics/` dir.

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

An epic's `**Status:**` is `open` until you mark it `done` (edit the epic file when all its tasks are verified/shipped).

Do not create an epic until you have a title. If the project is unconfigured, defer to `/workbench:setup` first.
