---
description: Health-check this workbench project — drift, stale state, in-review cap
allowed-tools: ["Bash", "Read", "Glob", "Grep"]
argument-hint: ""
---

Report this project's workbench health. Run the drift classifier and summarize:

!`bash ${CLAUDE_PLUGIN_ROOT}/scripts/drift.sh "$CLAUDE_PROJECT_DIR"`

Then add, from your own inspection:
- **In-review cap:** count `.claude/tasks/in-review/` vs `lifecycle.in_review_cap` in `.workbench/config.json`; warn if at/over.
- **SESSION_STATE freshness:** when was `.claude/SESSION_STATE.md` last updated (git log) — flag if stale (> a day during active work).
- **Decisions awaiting:** count `.claude/tasks/decisions/`.
- **Drift summary:** if any `managed` files show `edited`, or the plugin version advanced, recommend `/workbench:upgrade`.

Keep it to a compact report; recommend the single most useful next action.
