---
name: levels
description: Use when explaining the workbench maturity ladder (Solo/Pair/Crew/Fleet), how level presets map to coordination dials, how to override individual dials, and how graduation works.
---

# Workbench maturity ladder

## The four levels

The ladder is a **coordination surface** — it describes how much ceremony a project needs to stay coherent. It is not a ranking of quality.

| Level  | Coordination surface | Typical situation |
|--------|---------------------|-------------------|
| `solo` | One person, one voice | Single developer, main-only, personal projects |
| `pair` | Small-group alignment | 2–3 contributors, feature branches, light review |
| `crew` | Team coordination    | 3–8 people, tagged releases, epics, CI gates |
| `fleet` | Org-scale governance | 8+ contributors, release trains, federated repos |

The order is `solo → pair → crew → fleet`. Use `/workbench:level up` or `/workbench:level down` to move one step, or `/workbench:level <name>` to jump directly.

## Dials

Each level is a **preset** across seven dials. The dials are the real configuration; the level name is a convenient shorthand.

| Dial | What it controls |
|------|-----------------|
| `team` | Expected team topology (solo / pair / crew / fleet) |
| `release` | How changes reach production (push-to-main / feature-branch / tagged-releases / release-trains) |
| `decomposition` | Work breakdown style (tasks / light-epics / epics / themes-epics) |
| `architecture` | Context backbone formality (none / context / containers / components) |
| `surfaces` | Number of user-facing entry points (one / two / several / many) |
| `graphify` | Knowledge-graph scope (off / per-repo / workspace / federated) |
| `loop_autonomy` | How autonomous the teamlead loop runs (auto-continue / auto-continue / suggest-wait / suggest-review) |

### Level preset table

| Dial | solo | pair | crew | fleet |
|------|------|------|------|-------|
| `team` | solo | pair | crew | fleet |
| `release` | push-to-main | feature-branch | tagged-releases | release-trains |
| `decomposition` | tasks | light-epics | epics | themes-epics |
| `architecture` | none | context | containers | components |
| `surfaces` | one | two | several | many |
| `graphify` | off | per-repo | workspace | federated |
| `loop_autonomy` | auto-continue | auto-continue | suggest-wait | suggest-review |

## Presets over dials

**Always pick a level preset first.** It sets all seven dials coherently. Picking dials one by one risks incoherent combinations (e.g. `release=release-trains` with `team=solo`).

Only the level name is stored — `.workbench/config.json` holds `workbench.level`, and the seven dials are **derived from it at read-time** (via `wb_level_dials` in `scripts/levels.sh`). There is no persisted `dials` block to drift out of sync; change the level and every dial moves with it.

## Single-dial override

After applying a level, you can override one dial without leaving the preset by adding it to the optional flat `dial_overrides` object in `.workbench/config.json`:

```json
{
  "workbench": { "level": "crew" },
  "dial_overrides": { "graphify": "per-repo" }
}
```

The level label stays `crew` — it now means "crew preset, except `graphify=per-repo`." `wb_dial <project> <name>` resolves `dial_overrides.<name>` first and falls back to the level preset. Document the override in the project's CLAUDE.md if it matters for new agents.

## Lifecycle dirs per level

Each level adds task lifecycle directories that match its coordination needs:

| Level | Lifecycle dirs |
|-------|---------------|
| `solo` | backlog, in-development, verified, decisions |
| `pair` | + in-review |
| `crew` | + staged, shipped |
| `fleet` | + release-candidate |

The `decisions/` dir is always present at every level — it is the human-input queue.

When you move **up**, `init.sh` adds the missing dirs non-destructively (existing tasks are untouched). When you move **down**, existing dirs are **not removed** — removal is a deliberate manual step to avoid data loss.

## Graduation is recommend-only

`/workbench:level up` shows what changes and asks for confirmation. It does **not** force graduation. The right time to move up is when the current level's friction is real — not when the project is theoretically "ready."

For automated level suggestions based on git signals, see `scripts/graduate.sh` (Phase D). It analyzes commit patterns, contributor count, and branching model to recommend a level change — but the human always decides.

## Useful commands

- `/workbench:level` or `/workbench:level status` — print current level and all dials
- `/workbench:level up` — move one step up the ladder
- `/workbench:level down` — move one step down
- `/workbench:level <name>` — jump to a specific level
- `/workbench:doctor` — check for drift between config and actual files
