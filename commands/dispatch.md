---
description: Dispatch a backlog task to an engineer — move it to in-development and spawn the lane
allowed-tools: ["Bash", "Read", "Task", "TodoWrite"]
argument-hint: "<id> [--worktree [name]|--shared] [--background|--wait] [lane/repo]"
---

Dispatch a task to an engineer. Follow the `orchestration` skill — **you are the lead; you do not write the code yourself.**

1. Parse `$ARGUMENTS`: the task `<id>` (4-digit) and an optional lane/repo hint.
   - `--worktree [name]`: prefer a native Claude Code worktree lane. Use the given name or `wb-<id>-<slug>`.
   - `--shared`: avoid a persistent/background worktree and use the normal foreground Task-tool path. The engineer agent can still run in Claude's temporary `isolation: worktree` sandbox.
   - `--background`: for a native CLI lane, launch it with `claude --worktree <name> --bg --agent engineer "<prompt>"`.
   - `--wait`: keep the engineer in the current session foreground path.
   - if `--background` and `--wait` are both present, stop and ask the user to choose one.
2. Read the task file under `.claude/tasks/` for that id (its `## Why`, acceptance criteria, `**Repo(s):**`, `**Verification:**`).
3. **Claim the task** so no other live lead takes it (multi-teamlead safety — see the `coordination` skill). First check it's free, then claim it:
   - `bash "${CLAUDE_PROJECT_DIR}/scripts/coord/wb-coord" claims task:<id>` — if it reports the task claimed by another live session, STOP (someone else owns it).
   - otherwise `bash "${CLAUDE_PROJECT_DIR}/scripts/coord/wb-coord" claim task:<id>` (skip silently if `scripts/coord/wb-coord` doesn't exist — coordination is full-profile only).
   Then move it to in-development (you own lifecycle transitions):
   `bash "${CLAUDE_PLUGIN_ROOT}/scripts/task-move.sh" <id> in-development --target "${CLAUDE_PROJECT_DIR}"`
   and append an owner line to its `## Notes` (e.g. `<UTC time> — claimed by lead:<topic> (session <sid>)`).
   Set this session's durable lead purpose to the dispatched task:
   `bash "${CLAUDE_PLUGIN_ROOT}/scripts/lead.sh" set --target "${CLAUDE_PROJECT_DIR}" --session-id "<session-id>" --mode task --active-task "<id>" --track "<task Track field>" --purpose "<task title>"`
4. Resolve the engineer's model via the `models` skill (read `way_of_working.models`).
5. Choose the lane isolation path:
   - **Default / foreground:** spawn the engineer with the Task tool, `subagent_type: engineer`, passing the model and a prompt that includes: the task file path, the target repo/stack (from the lane hint or `config.project.repos`), and the instruction to implement, run the declared verification, commit (scoped pathspec, no Co-Authored-By), note progress, and report back. The `engineer` agent declares `isolation: worktree`, so current Claude Code releases put the subagent in a native temporary worktree.
   - **Native background worktree:** when the user asked for a background/worktree lane, or when a lead is running several same-repo lanes, launch Claude Code itself with `claude --worktree <name> --bg --agent engineer "<prompt>"`. Capture the printed background session id/management commands in the task notes, then use `claude agents --cwd "${CLAUDE_PROJECT_DIR}" --json` or `claude agents` to monitor it. Claude worktrees branch from the configured worktree base; when the lane must inherit the current branch/task move or unpushed context, commit/push the required state or set Claude Code `worktree.baseRef` to `"head"` before launch. If the first worktree launch reports a workspace trust error, run `claude` once in the repo to accept trust, then retry.
   - **Fallback:** if native `--worktree`/background launch is unavailable, use `scripts/coord/bb-worktree.sh new <name>` and start Claude from that checkout, or fall back to the current Task-tool lane.
6. When the engineer returns or a background worktree lane reports ready, **gate** it (review diff, build, run verification) per the `orchestration` skill — do not advance the task on the engineer's word alone. Then `/workbench:verify <id>`.

Never claim the task is done here — dispatch only starts the work.
