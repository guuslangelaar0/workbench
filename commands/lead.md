---
description: Set, inspect, adopt, or clear this session's durable lead purpose
allowed-tools: ["Bash", "Read", "AskUserQuestion"]
argument-hint: "[status|set \"<purpose>\"|adopt|clear]"
---

Manage this session's workbench lead purpose. Follow the `lead-purpose` skill.

Resolve the project first. If `${CLAUDE_PROJECT_DIR}/.workbench/config.json` does not exist, tell the user to run `/workbench:workbench` first.

## `status` or no arguments

Run:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/lead.sh" status --target "${CLAUDE_PROJECT_DIR}" --session-id "<session-id>"
```

If no purpose exists for this session, also run:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/lead.sh" latest-open --target "${CLAUDE_PROJECT_DIR}"
```

Then explain: continue the latest open purpose with `adopt`, or pick from backlog with `/workbench:loop`.

## `set "<purpose>"`

Set this session's purpose. Use mode `task` only when the purpose is tied to one task id; otherwise use `track` for a track lead or `backlog-scout` when the lead is intentionally triaging backlog.

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/lead.sh" set \
  --target "${CLAUDE_PROJECT_DIR}" \
  --session-id "<session-id>" \
  --mode "<task|track|backlog-scout|unassigned>" \
  --purpose "<purpose>" \
  [--active-task "<id>"] [--track "<track>"]
```

Then ping coordination if available:

```bash
bash "${CLAUDE_PROJECT_DIR}/scripts/coord/wb-coord" ping "lead:<short-purpose>"
```

Skip the ping silently if the coord script is absent.

## `adopt`

Read the latest open lead with `lead.sh latest-open`, extract its `purpose`, `mode`, `active_task`, and `track`, then write those values to this session with `lead.sh set`. Report what was adopted. If there is no open lead, say so and propose picking from backlog.

## `clear`

Close this session's purpose:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/lead.sh" clear --target "${CLAUDE_PROJECT_DIR}" --session-id "<session-id>"
```

Use this when the lead's task is verified/shipped, the track ownership ends, or the human explicitly redirects the session.
