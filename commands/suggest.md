---
description: Capture or review recommend-only suggestions — the home for a feature IDEA ("would be cool", "for later") and recommendations the loop surfaces (graduation, drift, anti-gaming, budget). An un-committed idea goes here via `add`, NOT in the task backlog (which is for committed work) and is never auto-built.
allowed-tools: ["Bash", "Read"]
argument-hint: "[list|act <key>|dismiss <key>|add ...]"
---

You are the `/workbench:suggest` command. Read `$ARGUMENTS` and act on it.

Suggestions are **recommend-only**: the loop surfaces options the way Claude surfaces tips, but nothing changes without the human. This is the third response mode — distinct from auto-acting (only bugs auto-file) and blocking to `decisions/` (only an expensive, irreversible fork). Most operational intelligence lives here.

## Resolve the project

If `${CLAUDE_PROJECT_DIR}/.workbench/config.json` (or legacy `.initlab/`) does not exist, tell the user: "This project isn't configured yet. Run `/workbench` to set it up." and stop.

The store is `<cfg>/suggestions/<key>.suggest` — keyed so a producer re-emitting the same suggestion is a no-op (no pile-up, no resurrecting a dismissed one). Everything goes through `scripts/suggest.sh`.

## `list` (default when no argument is given)

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/suggest.sh" list --target "${CLAUDE_PROJECT_DIR}"
```

Prints open suggestions ranked `warn > recommend > info`, each with its `key`, `why`, and the `how` command to act. Pass `--all` to include acted/dismissed. Relay the output and, if there are `warn`-level items, call them out first.

## `act <key>`

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/suggest.sh" act <key> --target "${CLAUDE_PROJECT_DIR}"
```

This **prints** the suggested command and marks the suggestion `acted` — it does **not** run anything (recommend-only). Show the user the command; run it only if they ask, or if the prime-directive forward-motion rule clearly applies and it is a safe, reversible action.

## `dismiss <key>`

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/suggest.sh" dismiss <key> --target "${CLAUDE_PROJECT_DIR}"
```

Marks it `dismissed` so it won't resurface. Use when the user says a recommendation isn't wanted.

## `add ...` (producers / manual)

Mostly used by producers (graduate, arch-drift, the anti-gaming guard, budget). A human can file one too:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/suggest.sh" add \
  --key <stable-key> --severity recommend --title "…" \
  --why "…" --how "/workbench:…" --source manual \
  --target "${CLAUDE_PROJECT_DIR}"
```

Choose a **stable key** that encodes the condition (e.g. `graduate-pair`, `gaming-0123`, `budget-80pct`) so re-emitting dedups instead of stacking.
