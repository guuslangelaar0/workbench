---
description: Fast preflight for "grab/start the next task/feature" — report in-review cap pressure or Blocked-by dependencies before dispatching
allowed-tools: ["Bash", "Read", "Glob", "Grep"]
argument-hint: "[task title/id hint]"
---

Find the next safe work item, or explain why none should be started yet. This command is the natural route for "grab the next feature", "start the next task from backlog", "start building <title>", and "what can I pick up now?"

Do not spawn an engineer, do not verify tasks, and do not move files. This is a cheap preflight that prevents the lead from opening more work when the queue is full or the requested task is blocked. After reporting cap pressure, blockers, or the safe `/workbench:dispatch <id>` command, stop.

1. If a task title/id hint was supplied, search `.claude/tasks/backlog/` for it before doing any product-scope or inception work. A matching existing task takes precedence over asking what to build.
2. Count in-review:
   `find "${CLAUDE_PROJECT_DIR}/.claude/tasks/in-review" -maxdepth 1 -type f -name '*.md' 2>/dev/null | wc -l`
   Read `.workbench/config.json` for `lifecycle.in_review_cap` if available; default to `10`. If `in_review >= cap - 3`, stop and report: the in-review cap is at/near the hard-drain threshold, so the next action is to drain/verify oldest in-review work before dispatching new work.
3. If the hinted task has `**Blocked-by:**` IDs that are not in `verified/` or `shipped/`, stop and report the blocker.
4. Otherwise run:
   `bash "${CLAUDE_PLUGIN_ROOT}/scripts/deps.sh" ready --target "${CLAUDE_PROJECT_DIR}"`
   and report the first ready backlog task by ID/title.
5. Tell the user the exact next command only when it is safe: `/workbench:dispatch <id>`.

Correct output includes the reason: cap/drain, blocked/dependency, or ready task. Never silently dispatch from this command.
