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

Reconcile **authored intent** (the docs) against **extracted reality** (graphify). Start with the automated assembler, which aligns the two for you:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/arch-drift.sh" "${CLAUDE_PROJECT_DIR}"
```

It parses the declared containers/components from your C4 tables and graphify's god-nodes (from `graphify-out/GRAPH_REPORT.md`, including per-repo graphs one level down), and prints an aligned comparison: which extracted core abstractions are named in your docs (`yes`/`no`) and which declared components have no extracted counterpart. **It does not pronounce verdicts** — its name-matching is a heuristic hint, because graphify's god-nodes include runtime/framework noise (wasm shims, UI toasts) that legitimately doesn't belong in a C4 model. If there's no graph, it says so and the check falls back to a manual read.

Then **you** do the judging the script deliberately won't:

1. For each god-node marked `no`, decide: real drift (a core abstraction you never documented → update intent) or just noise (ignore it).
2. For each declared component with no extracted match, decide: not-built-yet (fine), or stale intent (remove/revise).
3. Look past names too — dependencies/edges/datastores in the code but not in your diagram, god-nodes that have outgrown their box. Frame each under the docs' "Drift vs. extracted reality" section.
4. For each *real* drift, recommend the reconciliation (update intent vs. fix code) and, if it's work, offer to file it with `/workbench:task`.

Keep it honest: surface real drift, don't manufacture it from heuristic name mismatches, and don't hide it either.
