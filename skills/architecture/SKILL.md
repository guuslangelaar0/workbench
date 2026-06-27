---
name: architecture
description: Use when reading, writing, or reconciling a project's architecture docs (.claude/architecture/) — the C4-style context backbone that scales with the maturity level, the split between authored intent and graphify-extracted reality, and treating drift between them as a signal.
---

# The context backbone (C4)

A project's architecture lives in `.claude/architecture/`, modelled on [C4](https://c4model.com) and scaled by the `architecture` dial:

| Dial value | Level | Docs scaffolded |
|------------|-------|-----------------|
| `none` | solo | — (a single voice doesn't need a map) |
| `context` | pair | `context.md` (L1) |
| `containers` | crew | + `containers.md` (L2) |
| `components` | fleet | + `components.md` (L3) |

The docs are **cumulative** — `components` implies containers implies context. They are scaffolded by `init.sh` and re-rendered (non-destructively) on `/workbench:level up`.

## Authored intent ↔ extracted reality

The backbone has two sides, and the gap between them is the point:

- **Authored intent** — what you *mean* the system to be. The hand-written `.claude/architecture/*.md` docs: the C4 levels L1–L3 (context, containers, components).
- **Extracted reality** — what the system *actually is*. graphify extracts this from the code (the L4 "code" level and the real edges between modules/containers): god-nodes, community structure, actual call/import graph. It is **never hand-maintained** — read it from `graphify-out/` per the `graphify` dial.

**Drift is a first-class signal, not a failure.** When intent and reality diverge — a dependency in the code that isn't in `containers.md`, a component that's pure intent with no code, a module that's grown into a god-node — that divergence is information. Record it in the doc's "Drift vs. extracted reality" section and reconcile: either update the intent (the design changed) or fix the code (it drifted). At `crew`+ the maps are expected to stay current; unexplained drift becomes a task.

## How to use it

- **Before architectural work or answering "how does X relate to Y":** read the relevant `.claude/architecture/*.md` for intent, then the graphify graph for reality. Prefer graphify's `query`/`path`/`explain` over grepping files.
- **After a structural change:** update the affected architecture doc's intent, and (per the `graphify` dial) refresh the graph so reality stays current.
- **When they disagree:** treat it as drift — log it, decide which side is right, reconcile. Don't let intent and reality silently diverge.
- **To find drift:** run `/workbench:architecture drift` — it calls `scripts/arch-drift.sh` to align the declared containers/components (your C4 tables) against graphify's extracted god-nodes and print a `yes`/`no` "named in docs?" comparison plus declared-but-unextracted components. The assembler is deliberately heuristic and **never asserts a verdict** (graphify's hubs include runtime/framework noise that doesn't belong in a C4 model); you judge which mismatches are real drift.

## Composes with
`levels` (the dial that sets the depth) · `graphify` integration (extracted reality) · `task-lifecycle` (drift that needs fixing becomes a task). Automated intent-vs-extracted alignment ships via `scripts/arch-drift.sh` (`/workbench:architecture drift`); it does the mechanical comparison, you do the judging.
