---
description: Capture an irreversible architectural/product decision fork in .claude/tasks/decisions/ so the lead can keep moving elsewhere
allowed-tools: ["Bash", "Read", "AskUserQuestion", "Edit"]
argument-hint: "\"<decision title>\" [--context <summary>] | resolve <id> [--outcome \"<text>\"] [--to <state>]"
---

Create a durable decision item in this project's `.claude/tasks/decisions/`, or resolve one once the human has answered it.

Use creation for natural requests like "should we choose A or B?", "big architectural call", "expensive to reverse", crypto/schema/API/infra/dependency forks, or security/privacy choices that need human judgment before implementation.

## Create — default, when `$ARGUMENTS` is not `resolve ...`

1. Treat `$ARGUMENTS` as the decision title plus any context. If no title is present, derive a concise one-line title from the user's fork; if invoked bare with no fork to derive from, don't fail — run a short wizard: use AskUserQuestion for the decision title and the known options/tradeoffs (offer forks recently discussed or found in task `## Notes` as candidates), confirm, then create.
2. Run the creator with your Bash tool:
   `bash "${CLAUDE_PLUGIN_ROOT}/scripts/task-new.sh" --title "<title>" --state decisions --target "${CLAUDE_PROJECT_DIR}" --verification "human decision recorded"`
3. Append a short `## Options` section to the created file with the known options, tradeoffs, and the default recommendation if one is obvious. Keep it compact.
4. Report the decision ID/path and then continue with safe, unrelated work if any is available.

Do not bury irreversible forks in chat. Do not start implementing the chosen path until the human resolves the decision.

## Resolve — when `$ARGUMENTS` starts with `resolve <id>`

Once the human has answered the fork, close the loop instead of leaving it to rot in `decisions/`:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/decision-resolve.sh" <id> [--outcome "<what was decided>"] --target "${CLAUDE_PROJECT_DIR}"
```

This appends a `## Resolution` section (resolved-at timestamp + the `--outcome` text, if given) to the decision file, then moves it out of `decisions/` — to `backlog/` by default, so the now-unblocked work re-enters the normal task flow, unless the decision file itself declares a `**Resolution-target:**` override (or `--to <state>` is passed explicitly on the command line, which wins over both). This is the same git-mv + `**Status:**`-rewrite mechanism `task-move.sh` uses for every other lifecycle transition.

Report the resolved decision's new location, and — if the answer unblocks other queued work — go pick that up next.
