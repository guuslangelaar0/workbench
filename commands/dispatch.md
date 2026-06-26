---
description: Dispatch a backlog task to an engineer — move it to in-development and spawn the lane
allowed-tools: ["Bash", "Read", "Task", "TodoWrite"]
argument-hint: "<id> [lane/repo]"
---

Dispatch a task to an engineer. Follow the `orchestration` skill — **you are the lead; you do not write the code yourself.**

1. Parse `$ARGUMENTS`: the task `<id>` (4-digit) and an optional lane/repo hint.
2. Read the task file under `.claude/tasks/` for that id (its `## Why`, acceptance criteria, `**Repo(s):**`, `**Verification:**`).
3. **Claim the task** so no other live lead takes it (multi-teamlead safety — see the `coordination` skill). First check it's free, then claim it:
   - `bash "${CLAUDE_PROJECT_DIR}/scripts/coord/bb-coord" claims task:<id>` — if it reports the task claimed by another live session, STOP (someone else owns it).
   - otherwise `bash "${CLAUDE_PROJECT_DIR}/scripts/coord/bb-coord" claim task:<id>` (skip silently if `scripts/coord/bb-coord` doesn't exist — coordination is full-profile only).
   Then move it to in-development (you own lifecycle transitions):
   `bash "${CLAUDE_PLUGIN_ROOT}/scripts/task-move.sh" <id> in-development --target "${CLAUDE_PROJECT_DIR}"`
   and append an owner line to its `## Notes` (e.g. `<UTC time> — claimed by lead:<topic> (session <sid>)`).
4. Resolve the engineer's model via the `models` skill (read `way_of_working.models`). Spawn the engineer with the Task tool, `subagent_type: engineer`, passing the model and a prompt that includes: the task file path, the target repo/stack (from the lane hint or `config.project.repos`), and the instruction to implement, run the declared verification, commit (scoped pathspec, no Co-Authored-By), note progress, and report back.
5. When the engineer returns, **gate** it (review diff, build, run verification) per the `orchestration` skill — do not advance the task on the engineer's word alone. Then `/initlab:verify <id>`.

Never claim the task is done here — dispatch only starts the work.
