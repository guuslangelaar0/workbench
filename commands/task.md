---
description: Create a new task file in backlog/ (allocates the next ID, renders the canonical format)
allowed-tools: ["Bash", "Read", "AskUserQuestion"]
argument-hint: "\"<title>\" [--epic <id>] [--track T] [--repos a,b] [--estimate ~1d]"
---

Create a new task in this project's `.claude/tasks/backlog/`.

1. Treat `$ARGUMENTS` as the task title (plus any optional `--epic` / `--track` / `--repos` / `--estimate` the user passed). If no title is present, ask for a one-line title (and optionally epic / track / repos / estimate).
2. Run the creator with your Bash tool:
   `bash "${CLAUDE_PLUGIN_ROOT}/scripts/task-new.sh" --title "<title>" --target "${CLAUDE_PROJECT_DIR}" [--epic <epic-id>] [--track <t>] [--repos "<a,b>"] [--estimate "<e>"]`
   It allocates the next ID from `_next-id`, renders the canonical task template, and bumps the counter. `--epic <id>` links the task to an epic (see `/workbench:epic`); its progress then rolls up in `/workbench:mc`.
3. Report the created path + ID, and remind the user the task starts in `backlog/` — fill in `## Why`, `## Acceptance criteria`, and `**Verification:**`, then `/workbench:dispatch <id>` to start it. See the `task-lifecycle` skill for the format.
