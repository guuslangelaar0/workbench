---
description: Park an out-of-scope bug, feature idea, or follow-up as a real backlog task with origin metadata
allowed-tools: ["Bash", "Read", "AskUserQuestion", "Grep"]
argument-hint: "\"<title>\" [--type bug|feature|follow-up]"
---

Park work that does not belong to the current lead purpose. Follow the `lead-purpose` skill.

1. Resolve the title and type from `$ARGUMENTS`. Default type is `follow-up`; use `bug` for defects and `feature` for new capability ideas. If the title is missing, ask for one short title.
2. Read the current lead purpose:

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/lead.sh" status --target "${CLAUDE_PROJECT_DIR}" --session-id "<session-id>"
   ```

   If none exists, continue with empty origin fields, but tell the user the session has no lead purpose yet.
3. If there is already code for the tangent, capture the relevant context or diff in a temp file. Do not revert anything yet. Reverts require explicit user confirmation and must not touch in-scope hunks.
4. Create a backlog task:

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/park.sh" \
     --target "${CLAUDE_PROJECT_DIR}" \
     --session-id "<session-id>" \
     --type "<bug|feature|follow-up>" \
     --title "<title>" \
     --origin-task "<active-task-if-known>" \
     --origin-purpose "<current-purpose-if-known>" \
     [--context-file "<path>"]
   ```

5. Report the created task id/path and state that the current lead purpose remains unchanged. Do not start implementing the parked work.
