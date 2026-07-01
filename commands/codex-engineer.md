---
description: Dispatch a task to a native Codex engineer lane through the OpenAI Codex plugin
allowed-tools: ["Bash", "Read", "Agent", "TodoWrite"]
argument-hint: "<id> [--background|--wait] [--fresh|--resume] [--model <model|spark>] [--effort <none|minimal|low|medium|high|xhigh>] [lane/repo]"
---

Dispatch a task to Codex through the native OpenAI Codex plugin. Use this when the user says "dispatch this to Codex", "use Codex as the engineer", "give task 0042 to Codex", or asks for an independent Codex implementation lane.

You are still the Workbench lead. Codex is the engineer. You own task lifecycle, review, and verification after Codex returns.

1. Parse `$ARGUMENTS`:
   - first non-flag token is the 4-digit task id
   - preserve `--background`, `--wait`, `--fresh`, `--resume`, `--model <value>`, and `--effort <value>` for the Codex request
   - treat remaining text as a lane/repo hint
   - if no task id is present, ask for the task id

2. Read the task file under `${CLAUDE_PROJECT_DIR}/.claude/tasks/` for that id. Capture:
   - task file path
   - title
   - `**Track:**`
   - `**Repo(s):**`
   - `**Verification:**`
   - `## Acceptance criteria`
   - `## Scenarios`
   - `## Verification ladder`

3. If the OpenAI Codex plugin or `codex:codex-rescue` subagent is unavailable when invoking `Agent`, stop and tell the user to run `/codex:setup`. Do not call another plugin's private runtime directly from Workbench.

4. Check `way_of_working.codex` in `.workbench/config.json` when present:
   - `off`: continue only if the user explicitly asked for Codex; say the handoff is user-directed
   - `rescue-only`: use Codex for stuck work, second implementation passes, or explicit user requests
   - `full-lane`: Codex is an available engineer lane

5. Claim the task before moving it, when coordination is available:
   - `bash "${CLAUDE_PROJECT_DIR}/scripts/coord/wb-coord" claims task:<id>`
   - if another live session owns it, STOP and report the owner
   - otherwise `bash "${CLAUDE_PROJECT_DIR}/scripts/coord/wb-coord" claim task:<id>`
   - skip this silently when `scripts/coord/wb-coord` is absent

6. Move the task to in-development:
   `bash "${CLAUDE_PLUGIN_ROOT}/scripts/task-move.sh" <id> in-development --target "${CLAUDE_PROJECT_DIR}"`

7. Append a note to the task's `## Notes` section. Include UTC time, that Codex was assigned, the runtime mode (`--background` or `--wait`), and any `--model`/`--effort` flags. If there is no `## Notes` section, append one.

8. Set this lead session's purpose to the Codex-dispatched task:
   `bash "${CLAUDE_PLUGIN_ROOT}/scripts/lead.sh" set --target "${CLAUDE_PROJECT_DIR}" --session-id "<session-id>" --mode task --active-task "<id>" --track "<task Track field>" --purpose "<task title>"`

9. Invoke the `Agent` tool with `subagent_type: "codex:codex-rescue"`. Forward this prompt to Codex, preserving explicit runtime flags:

```text
You are Codex acting as a Workbench engineer lane.

Project root: <CLAUDE_PROJECT_DIR>
Current branch: <git branch --show-current output>
Task id: <id>
Task file: <task file path>
Lane/repo hint: <lane hint or "(none)">

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
- Run the declared verification and report exact commands/results.
- Do not mark the task verified. Workbench will run /workbench:verify after you return.
```

10. If the `Agent` call fails after the task was claimed or moved, append a task note saying Codex launch failed and leave the task in `in-development` for the lead to re-dispatch or move back.

11. When Codex returns, report that the task is ready for Workbench verification. Do not claim it is done. Tell the user or lead to run `/workbench:verify <id>`.
