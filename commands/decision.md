---
description: Capture an irreversible architectural/product decision fork in .claude/tasks/decisions/ so the lead can keep moving elsewhere
allowed-tools: ["Bash", "Read", "AskUserQuestion", "Edit"]
argument-hint: "\"<decision title>\" [--context <summary>]"
---

Create a durable decision item in this project's `.claude/tasks/decisions/`.

Use this for natural requests like "should we choose A or B?", "big architectural call", "expensive to reverse", crypto/schema/API/infra/dependency forks, or security/privacy choices that need human judgment before implementation.

1. Treat `$ARGUMENTS` as the decision title plus any context. If no title is present, derive a concise one-line title from the user's fork; only ask if the fork is genuinely unclear.
2. Run the creator with your Bash tool:
   `bash "${CLAUDE_PLUGIN_ROOT}/scripts/task-new.sh" --title "<title>" --state decisions --target "${CLAUDE_PROJECT_DIR}" --verification "human decision recorded"`
3. Append a short `## Options` section to the created file with the known options, tradeoffs, and the default recommendation if one is obvious. Keep it compact.
4. Report the decision ID/path and then continue with safe, unrelated work if any is available.

Do not bury irreversible forks in chat. Do not start implementing the chosen path until the human resolves the decision.
