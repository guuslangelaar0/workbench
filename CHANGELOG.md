# Changelog

All notable changes to workbench are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/), and the project aims to adhere to
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- **Verification contract** (loop hardening): the task template now carries an enforceable definition of done — acceptance criteria, scenarios (happy + edge), and a verification ladder (self-test → unit → integration → e2e/Playwright → evidence). `scripts/verify-gate.sh` checks it, and `task-move.sh` **refuses** to move a task into `verified`/`staged`/`shipped` without real criteria + captured evidence (level-scaled: enforced at crew/fleet, advisory at solo/pair; `WB_SKIP_VERIFY_GATE=1` overrides). A `TeammateIdle` hook nudges teammates not to idle on unverifiable in-review work. Makes "verified" structurally unfakeable.

- **Automated architecture-drift assembler** (`scripts/arch-drift.sh`, wired into `/workbench:architecture drift`): aligns the declared containers/components in your C4 tables against graphify's extracted god-nodes and prints a `yes`/`no` "named in your docs?" comparison plus declared-but-unextracted components. Deliberately a heuristic *assembler*, not a verdict engine — graphify's hubs include runtime/framework noise (wasm shims, UI toasts) that doesn't belong in a C4 model, so the script aligns and the human judges. Falls back to a manual read when no graph is present.

### Changed
- **Loop hardening — correctness:** dropped the removed `TeamCreate`/`TeamDelete` instruction from the orchestration skill (Claude Code v2.1.178 auto-forms teams on first spawn; `team_name` is ignored).

## [0.1.0] - 2026-06-27

First public release. The full foundation roadmap (Specs 1–5) is implemented,
covered by 30 offline test suites plus a 6-scenario live-plugin e2e harness, and
validated as publishable.

### Added
- **Context backbone** (Spec 4): C4-style architecture docs in `.claude/architecture/`, scaffolded cumulatively per the `architecture` dial (pair=context → crew=+containers → fleet=+components; solo=none) and added non-destructively on level-up. Models authored intent (the docs) vs. graphify-extracted reality, with drift as a first-class signal. `/workbench:architecture [view|drift]` + the `architecture` skill. (Automated intent-vs-extracted diffing is the next layer.)
- **Marketplace distribution** (Spec 5): `scripts/validate-plugin.sh` publishability gate — validates the manifests (JSON, required fields, name/version consistency, license matches the LICENSE file, plugin exposes surfaces). Fixed plugin.json metadata for publication (MIT license to match the LICENSE file, correct homepage/repository, keywords).
- **Adoption level detection** (Spec 3): `scripts/detect-level.sh` recommends a starting maturity level for an existing repo from git/repo signals (committers, release tags, non-trunk branches, repo count), taking the strongest signal. The setup wizard runs it and recommends — recommend-only, you decide.
- **Epics** (Spec 2): group related tasks under one outcome via `.claude/epics/NNNN-title.md`. `/workbench:epic` to create/list; `/workbench:task --epic <id>` to link; live `done/total` rollup in `/workbench:mc`. Epics draw from the shared task ID counter (no collisions) and are gated to levels whose `decomposition` is grouped (pair+). `solo` stays flat.
- Maturity ladder (`solo` / `pair` / `crew` / `fleet`) as the spine: each level is a preset over seven coordination dials, with single-dial `dial_overrides`.
- `/workbench` single front door (context-aware: setup if unconfigured, else status).
- `/workbench:level` to show or change the level (graduation is recommend-only).
- Level-derived task lifecycle: stages scale with the level (`solo` skips `in-review`; `crew` adds `staged`/`shipped`; `fleet` adds `release-candidate`).
- Autonomous orchestration loop with inverse-to-level autonomy and the rule "bugs auto-file, features only suggest."
- Session & compaction continuity (`SessionStart` re-ground, `PreCompact` checkpoint, `SESSION_STATE.md` handoff).
- Multi-session coordination (presence, task claims, pre-commit collision guard, worktrees).
- `/workbench:inception` scope-controlled greenfield genesis; `/workbench:remote` Telegram control with a catastrophic-command guard.
- Live-plugin end-to-end test harness (`test/e2e/run.sh`) that loads the real plugin into a headless Claude session via `claude -p --plugin-dir` — 6 scenarios / 9 checks covering `task`, `mc`, `level`, the front door, `epic`, and `architecture`.
- User documentation: getting-started, levels, concepts, commands, configuration.

### Changed
- Config model is **level-only**: `.workbench/config.json` stores `workbench.level` and the seven dials + lifecycle stages are derived from it at read-time. No persisted `dials` block or `lifecycle.states` array to drift.

### Notes
- This is the `0.x` foundation: the full Spec 1–5 roadmap ships here (see [docs/design/](docs/design/)). The next layer is automated intent-vs-extracted drift diffing for the context backbone.
