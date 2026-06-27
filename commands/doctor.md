---
description: Health-check this workbench project — drift, stale state, in-review cap
allowed-tools: ["Bash", "Read", "Glob", "Grep"]
argument-hint: ""
---

Report this project's workbench health. Run the drift classifier and summarize:

!`bash ${CLAUDE_PLUGIN_ROOT}/scripts/drift.sh "$CLAUDE_PROJECT_DIR"`

Also report loop health — list lanes and flag phantoms:

!`bash ${CLAUDE_PLUGIN_ROOT}/scripts/lane.sh list --target "$CLAUDE_PROJECT_DIR" 2>/dev/null; bash ${CLAUDE_PLUGIN_ROOT}/scripts/lane.sh reap --target "$CLAUDE_PROJECT_DIR" 2>/dev/null`

Then add, from your own inspection:
- **Phantom lanes:** any lane the reap above reports `DEAD` (heartbeat stale) is a worker that died — its task in `in-development/` needs re-dispatch (or `lane.sh clear <id>` if the work landed). A lane with a high `attempts` count is a repeatedly-failing task — surface it.
- **In-review cap:** count `.claude/tasks/in-review/` vs `lifecycle.in_review_cap` in `.workbench/config.json`; warn if at/over.
- **SESSION_STATE freshness:** when was `.claude/SESSION_STATE.md` last updated (git log) — flag if stale (> a day during active work).
- **Charter present:** flag if `.workbench/loop-charter.md` is missing (the loop has no durable north star to re-ground from).
- **Unverifiable tasks:** any task in `in-review/` whose `## Acceptance criteria` is still the `...` placeholder or whose `## Verification evidence` is empty — it cannot pass the gate (`crew`+); flag it.
- **Decisions awaiting:** count `.claude/tasks/decisions/`.
- **Drift summary:** if any `managed` files show `edited`, or the plugin version advanced, recommend `/workbench:upgrade`.

Keep it to a compact report; recommend the single most useful next action.
