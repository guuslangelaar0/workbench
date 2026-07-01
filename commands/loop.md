---
description: Run the teamlead loop for "grab next/start next backlog work" — first drain in-review cap, honor Blocked-by dependencies, then dispatch/verify
allowed-tools: ["Bash", "Read", "Edit", "Write", "Glob", "Grep", "Task", "TodoWrite", "ScheduleWakeup"]
---

Run the workbench orchestration loop for this project. **Invoke the `orchestration` skill and follow it exactly** — you are the lead coordinator and you never write code directly.

Fast natural-language mapping:

- "Keep going" or "run the loop" means this command.
- "Grab/pull the next task", "start the next feature from backlog", or "what can I pick up now?" should first use `/workbench:next` for the cheap cap/dependency preflight.
- First check `/workbench:mc` and the in-review cap. If the queue is at/over hard-drain, report that cap pressure and verify/drain instead of opening new work.
- Use `deps.sh ready` / `deps.sh blocked`; never dispatch a task whose `**Blocked-by:**` dependency is unfinished.
- For a brand-new committed feature with no task yet, create `/workbench:task` first, then come back here.

1. Start with a reality check: `/workbench:mc` (task counts, in-review vs cap, decisions, build, prod). Trust disk over memory.
2. Then run the loop from the `orchestration` skill: drain in-review (hard-drain at `cap − 3`) → pick the highest-impact unblocked task → `/workbench:dispatch` it to an engineer → gate and `/workbench:verify` → lifecycle `git mv` → surface honesty triggers to `decisions/` without stopping → checkpoint `SESSION_STATE.md` on cadence (`session-continuity`) → **never stop**; always pick the next task.
3. Respect `way_of_working` tiers (models, verification, review, parallelism) and the in-review cap throughout.

Keep 2–3 tasks queued per lane. Surface decisions to `.claude/tasks/decisions/` and keep going — do not park the loop waiting on the human.

**Never wait blind on a completion notification.** After dispatching background work (engineers/verifiers/workflows), schedule a self-paced fallback heartbeat (`ScheduleWakeup` — the `/loop` mechanism) so a dropped signal or a silently-dead agent can't strand you. On wake, reconcile against disk (commits, branches, task `## Notes`), gate what finished, and **re-dispatch what died** — don't re-wait. Cadence is cache-aware: ~`1200s` for in-process subagents, `≤270s` only for fast external state. See the `orchestration` skill, Step 4b.

**When the backlog drains**, read the autonomy mode before deciding what to do next:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/loop-policy.sh" "${CLAUDE_PROJECT_DIR}"
```

The script returns `auto-continue`, `suggest-wait`, or `suggest-review`. Follow the **Loop engineering** section of the `orchestration` skill for what each mode means. Never hard-code the behavior — always read it from the script.
