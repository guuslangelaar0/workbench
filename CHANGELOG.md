# Changelog

All notable changes to workbench are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/), and the project aims to adhere to
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
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
- Live-plugin end-to-end test harness (`test/e2e/run.sh`) that loads the real plugin into a headless Claude session via `claude -p --plugin-dir`.
- User documentation: getting-started, levels, concepts, commands, configuration.

### Changed
- Config model is **level-only**: `.workbench/config.json` stores `workbench.level` and the seven dials + lifecycle stages are derived from it at read-time. No persisted `dials` block or `lifecycle.states` array to drift.

### Notes
- This is the `0.x` foundation. The deeper context-backbone implementation, epics/lifecycle file model, and marketplace polish are on the roadmap (see [docs/design/](docs/design/)).
