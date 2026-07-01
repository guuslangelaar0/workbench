---
description: Create a tracked task in backlog/ — use for committed work, "start work on X", bugs, security bugs, and concrete fixes before any implementation
allowed-tools: ["Bash", "Read", "AskUserQuestion"]
argument-hint: "\"<title>\" [--epic <id>] [--track T] [--repos a,b] [--estimate ~1d]"
---

Create a new task in this project's `.claude/tasks/backlog/`.

Natural intent mapping:

- "Let's start work on X", "we need X", "build/fix X" where X is concrete committed work: create the task first. Do not start coding before there is a task file.
- Multi-part planning at solo/pair/crew should create lightweight flat backlog task stubs for the named parts first; do not turn the capture step into a full spec, provider decision, git initialization, or commit unless the user asks for that depth.
- Bugs, crashes, regressions, security/privacy bugs, leaked secrets/passwords, and failing checks are auto-filed as tasks. Track them on disk instead of only discussing them.
- If the repo/code location is missing or ambiguous, still create the task. Put "locate affected repo/code path" in the notes or acceptance criteria; do not refuse to file the bug because the fix target is unclear.
- "Would be cool", "for later", or speculative ideas belong in `/workbench:suggest add`, not here.

1. Treat `$ARGUMENTS` as the task title (plus any optional `--epic` / `--track` / `--repos` / `--estimate` the user passed). If no title is present, ask for a one-line title (and optionally epic / track / repos / estimate).
2. Run the creator with your Bash tool:
   `bash "${CLAUDE_PLUGIN_ROOT}/scripts/task-new.sh" --title "<title>" --target "${CLAUDE_PROJECT_DIR}" [--epic <epic-id>] [--track <t>] [--repos "<a,b>"] [--estimate "<e>"]`
   It allocates the next ID from `_next-id`, renders the canonical task template, and bumps the counter. `--epic <id>` links the task to an epic (see `/workbench:epic`); its progress then rolls up in `/workbench:mc`.
3. Report the created path + ID. If the user explicitly asked to start work now, next check `/workbench:mc` for in-review pressure and dependency blockers before dispatching. If it is just a captured bug/security issue, say it is tracked and ready to prioritize.
