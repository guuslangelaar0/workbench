---
description: View or reconcile the project's architecture backbone (C4 docs + drift vs reality)
allowed-tools: ["Bash", "Read"]
argument-hint: "[view | drift]"
---

You are the `/workbench:architecture` command. The architecture backbone lives in `.claude/architecture/` — C4-style authored-intent docs that scale with the `architecture` dial (context → containers → components). See the `architecture` skill for the model.

Read `$ARGUMENTS`:

## `view` (default)

List and summarize the architecture docs that exist:

```bash
ls "${CLAUDE_PROJECT_DIR}/.claude/architecture/" 2>/dev/null
```

Read each present doc (`context.md`, `containers.md`, `components.md`) and give a tight summary of the system's intended shape. If the directory doesn't exist, tell the user their level's `architecture` dial is `none` (solo) — `/workbench:level up` enables the backbone — and stop.

## `drift`

Reconcile **authored intent** (the docs) against **extracted reality** (graphify):

1. Read the authored docs in `.claude/architecture/`.
2. Read the extracted graph if present — `graphify-out/GRAPH_REPORT.md` (and per-repo graphs for multi-repo). If graphify isn't set up, say so and point at the `graphify` dial.
3. Compare: dependencies/containers/components in the code but not the docs (or vice versa), god-nodes, components with no code yet. List each divergence under the doc's "Drift vs. extracted reality" framing.
4. For each real drift, recommend the reconciliation (update intent vs. fix code) and, if it's work, offer to file it with `/workbench:task`. Drift is a signal — surface it, don't hide it.

Keep it honest: if there's no graph to compare against, say the drift check is a manual read, not an automated diff.
