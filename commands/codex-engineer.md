---
description: Dispatch a task to a native Codex engineer lane through the OpenAI Codex plugin
allowed-tools: ["Bash", "Read", "Agent", "TodoWrite"]
argument-hint: "<id> [--background|--wait|--reconcile] [--fresh|--resume] [--model <model|spark>] [--effort <none|minimal|low|medium|high|xhigh>] [lane/repo]"
---

Dispatch a task to Codex through the native OpenAI Codex plugin. Use this when the user says "dispatch this to Codex", "use Codex as the engineer", "give task 0042 to Codex", or asks for an independent Codex implementation lane.

You are still the Workbench lead. Codex is the engineer. You own task lifecycle, review, and verification after Codex returns.

Codex completion notifications are best-effort. Codex may finish and disappear from the active thread list without sending the same second callback Claude engineer lanes send. Treat the task file, git state, lane lease, and `claude agents` as the source of truth.
The disk lease commands are `lane.sh start`, `lane.sh status`, and `lane.sh beat`; they make Codex progress visible even when the callback is dropped.

1. Parse `$ARGUMENTS`:
   - first non-flag token is the 4-digit task id
   - preserve `--fresh`, `--resume`, `--model <value>`, and `--effort <value>` for the Codex request
   - build a `runtime_flags` string from preserved `--fresh`/`--resume`, `--model <value>`, and `--effort <value>` flags, or `(none)` when no such flags were passed
   - map `--background` to Agent `run_in_background: true`
   - map `--wait` to Agent `run_in_background: false`
   - `--reconcile`: do not launch a new Codex lane; inspect the existing Codex lane/task state and decide whether it is ready for Workbench verification
   - if both `--background` and `--wait` are present, stop and ask the user to choose one
   - treat remaining text as a lane/repo hint
   - if no task id is present, ask for the task id

2. If `--reconcile` was passed:
   - run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/lane.sh" status <id> --target "${CLAUDE_PROJECT_DIR}"` when available
   - run `claude agents --cwd "${CLAUDE_PROJECT_DIR}" --json` if supported, otherwise `claude agents`, and check whether a Codex/Codex-rescue thread is still active
   - inspect `git -C "${CLAUDE_PROJECT_DIR}" status --short`, recent commits, and the task `## Notes`
   - if there is no active Codex thread and Codex left commits/edits/verification notes, report that the lane appears finished and run the normal Workbench gate/review flow; tell the user to run `/workbench:verify <id>`
   - if there is no active Codex thread and no artifacts, mark the lane dead with `bash "${CLAUDE_PLUGIN_ROOT}/scripts/lane.sh" reap --mark --target "${CLAUDE_PROJECT_DIR}"` when available, append a task note, and ask whether to re-dispatch
   - if Codex is still active, report that it is still running and schedule/check again later; never wait only for a notification

3. Read the task file under `${CLAUDE_PROJECT_DIR}/.claude/tasks/` for that id. Capture:
   - task file path
   - title
   - `**Track:**`
   - `**Repo(s):**`
   - `**Verification:**`
   - `## Acceptance criteria`
   - `## Scenarios`
   - `## Verification ladder`

4. If the OpenAI Codex plugin or `codex:codex-rescue` subagent is unavailable when invoking `Agent`, stop and tell the user to run `/codex:setup`. Do not call another plugin's private runtime directly from Workbench.

5. Check `way_of_working.codex` in `.workbench/config.json` when present:
   - `off`: continue only if the user explicitly asked for Codex; say the handoff is user-directed
   - `rescue-only`: use Codex for stuck work, second implementation passes, or explicit user requests
   - `full-lane`: Codex is an available engineer lane

6. Claim the task before moving it, when coordination is available:
   - `bash "${CLAUDE_PROJECT_DIR}/scripts/coord/wb-coord" claims task:<id>`
   - if another live session owns it, STOP and report the owner
   - otherwise `bash "${CLAUDE_PROJECT_DIR}/scripts/coord/wb-coord" claim task:<id>`
   - skip this silently when `scripts/coord/wb-coord` is absent

7. Move the task to in-development:
   `bash "${CLAUDE_PLUGIN_ROOT}/scripts/task-move.sh" <id> in-development --target "${CLAUDE_PROJECT_DIR}"`

8. Start a disk lane lease before invoking Codex, when `scripts/lane.sh` is available:
   `bash "${CLAUDE_PLUGIN_ROOT}/scripts/lane.sh" start <id> --owner codex --target "${CLAUDE_PROJECT_DIR}"`
   This is the fallback source of truth when Codex finishes without a callback. If `lane.sh` is unavailable, continue and note that the lane is untracked.

9. Append a note to the task's `## Notes` section. Include UTC time, that Codex was assigned, the Agent runtime mode (`--background`, `--wait`, or default foreground behavior), the `runtime_flags` string, and the reconcile command: `/workbench:codex-engineer <id> --reconcile`. If there is no `## Notes` section, append one.

10. Set this lead session's purpose to the Codex-dispatched task:
   `bash "${CLAUDE_PLUGIN_ROOT}/scripts/lead.sh" set --target "${CLAUDE_PROJECT_DIR}" --session-id "<session-id>" --mode task --active-task "<id>" --track "<task Track field>" --purpose "<task title>"`

11. Invoke the `Agent` tool with `subagent_type: "codex:codex-rescue"`. Set `run_in_background: true` when `--background` was passed and `run_in_background: false` when `--wait` was passed. Forward this prompt to Codex, preserving explicit runtime flags:

```text
You are Codex acting as a Workbench engineer lane.

Project root: <CLAUDE_PROJECT_DIR>
Current branch: <git branch --show-current output>
Task id: <id>
Task file: <task file path>
Lane/repo hint: <lane hint or "(none)">
Runtime flags: <runtime flags or "(none)">

Task title:
<title>

Task fields:
- Track: <track>
- Repo(s): <repos>
- Verification: <verification>

Acceptance criteria:
<acceptance criteria section>

Scenarios:
<scenarios section>

Verification ladder:
<verification ladder section>

Workbench rules:
- Implement only this task.
- Keep commits scoped to this task.
- Do not add Co-Authored-By.
- Update the task notes with what you changed and what you verified.
- Run `bash <CLAUDE_PLUGIN_ROOT>/scripts/lane.sh beat <id> --target <CLAUDE_PROJECT_DIR>` after meaningful progress when that script exists.
- Run the declared verification and report exact commands/results.
- Do not mark the task verified. Workbench will run /workbench:verify after you return.
```

12. If the `Agent` call fails after the task was claimed or moved, append a task note saying Codex launch failed and leave the task in `in-development` for the lead to re-dispatch or move back.

13. When Codex returns, report that the task is ready for Workbench verification. Do not claim it is done. Tell the user or lead to run `/workbench:verify <id>`.

14. If Codex does not return but `claude agents` shows no active Codex thread anymore, immediately run `/workbench:codex-engineer <id> --reconcile`. Do not wait for a second notification.
