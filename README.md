# initlab

An operating system for AI-orchestrated product building. `initlab` scaffolds and maintains a complete way of working — teamlead orchestration loop, file-based task lifecycle, session/compaction continuity, multi-session coordination, the brainstorm->spec->plan discipline, graphify, Codex collaboration, and Telegram remote control — and keeps it active across compaction and new sessions.

Design spec: `docs/superpowers/specs/2026-06-20-initlab-plugin-design.md`.
Build plans: `docs/superpowers/plans/2026-06-20-initlab-*.md`.

## Status

**Build COMPLETE — Plans 1–9, 20 test suites green** (`bash tools/initlab/test/all.sh`). Every plan was Opus-reviewed (each caught and fixed a real bug). The one remaining check is the live `/plugin install` round-trip below — Guus-only, since no automated test can load the plugin into a real Claude Code session.

Plan 1 (Foundation): installable plugin + `/initlab:init` minimal scaffold + config/manifest + tests.

Plan 2 (Full Templates): complete. The default (`full`) profile now renders SOUL.md, AGENTS.md, and a full CLAUDE.md that cross-references them, alongside the 6-file `scripts/coord/` coordination suite (bb-coord, bb-worktree, with-lock, precommit-guard, lib, install-hooks). The manifest tracks each scaffolded file with an explicit update mode (`merge`, `managed`, or `once`). `_next-id` is preserved across re-runs (the `once` mode guards it). The git pre-commit guard installs into the target repo on first scaffold.

Plan 3 (Continuity): complete. Continuity hooks: SessionStart re-ground (disk-derived operating brief injected as context), PreCompact checkpoint (writes a durable compaction marker + SESSION_STATE breadcrumb), PostToolUse coord-ping (throttled presence heartbeat). SESSION_STATE.md handoff template (once-mode, preserved on re-run). `/initlab:boot` and `/initlab:checkpoint` commands. `session-continuity` skill covering boot protocol, checkpoint discipline, and restart hygiene.

Plan 4 (Setup Wizard + Front Door): complete. Guided per-axis setup wizard (`setup` skill) walks each configuration axis as `AskUserQuestion` cards with Recommended/Better/Leaner options + plain-language cost notes, writes `.initlab/config.json`, then scaffolds. `init.sh` now preserves an existing config (the wizard owns it; init only scaffolds templates + manifest around it). Bare `/initlab` is the front door — auto-runs setup if unconfigured, else shows status + next actions. Any `/initlab:*` command defers to setup when the project is unconfigured (auto-trigger pattern).

Plan 5 (Upgrade Engine + Doctor + Codex Bridge): complete. `/initlab:upgrade` reconciles a project's generated files to the current plugin version — regenerating untouched mechanism files, semantically merging user-edited docs, never clobbering edits silently. `/initlab:doctor` reports drift + health. `scripts/drift.sh` classifies each managed file as `ok`, `edited`, or `missing` using the manifest. Codex bridge: `CODEX_COORDINATION.md` + teamlead prompt render conditionally when `codex != off` in the project config; `codex-bridge` skill wires `codex:rescue`/`codex:setup`. Schemas hardened: `rendered_hash` pattern, `lifecycle.states` enum, `way_of_working` required fields.

Plan 6 (Orchestration): complete. The teamlead loop — `orchestration` + `task-lifecycle` + `models` skills, `engineer`/`verifier` agents, `/loop` `/task` `/dispatch` `/verify` `/mc` commands, the `task-new.sh`/`task-move.sh`/`mc.sh` scripts (the absorbed + generalized mission-control dashboard, config-driven), and the optional `**Estimate:**` task field.

Plan 7 (Multi-teamlead + Coordination): complete. `coordination` skill (the A+B+C presence/locks/worktrees model), `/initlab:teamlead <topic>` (Track-scoped topic leads), and task-locking — `bb-coord` gained a `claims` query + a Claims section in `status` + claim de-dup so a second lead can see a lock. The scaffold now gitignores `.claude/locks/`.

Plan 8 (Inception): complete. The `inception` skill + `/initlab:inception` — a scope-controlled product-genesis brainstorm that refuses to proceed until you name what's explicitly OUT of v1. Composes `superpowers:brainstorming` (+ `grill-me`/`frontend-design` at the `better` tier), seeds the backlog via `/initlab:task`, Mermaid specs.

Plan 9 (Remote + Dogfood): complete. The `remote` skill + `/initlab:remote` (operating the official Telegram Channels plugin + the security model), a `Notification`→Telegram outbound hook, and a `PreToolUse` guard (`remote-guard.sh`) that hard-blocks catastrophic `rm -rf`/force-push on remote-driven sessions. De-beebeeb'd the coord commit-guard advice; a `dogfood.test.sh` end-to-end integration smoke.

## Install & smoke-test (the live round-trip)

Run this once to confirm the plugin loads into a real Claude Code session and its hooks fire — the one check the 20 unit suites can't cover.

**1. Install** (from a Claude session at the workspace root — `/home/guus/code/beebeeb.io` here):

```text
/plugin marketplace add ./tools
/plugin install initlab@beebeeb-local
/reload-plugins
```

`/plugin marketplace add` takes the directory that contains `.claude-plugin/marketplace.json` (here `tools/`; an absolute path works from anywhere); the marketplace registers as `beebeeb-local`. Install enables the plugin by default; `/reload-plugins` activates its hooks in the current session. Confirm it loaded:

```text
/plugin list      → initlab@beebeeb-local, enabled
/help             → /initlab:* commands appear
/agents           → engineer, verifier
```

**2. Smoke-test in a scratch project.** The hooks gate on `.initlab/config.json`, so scaffold a throwaway project first:

```sh
mkdir -p ~/initlab-smoke && cd ~/initlab-smoke && git init && claude
```

Then, in that scratch session:

1. **Scaffold** — run `/initlab` (the bare front door auto-runs setup when unconfigured) or `/initlab:setup`, and walk the per-axis wizard. Confirm it wrote `.initlab/config.json`, `CLAUDE.md`, `.claude/tasks/{backlog,in-development,in-review,verified,decisions}/`, `.claude/SOUL.md`, and `scripts/coord/`.
2. **Confirm the `SessionStart` hook fires** — it only fires on a *fresh* session (not on `/reload-plugins`). Exit and re-launch `claude` in `~/initlab-smoke`; on startup you should see the operating brief print — `=== initlab operating brief: <project> ===` with task counts. That's the re-ground hook working.
3. **Exercise the loop surface** — `/initlab:task "smoke test"` (creates `0001-smoke-test.md` in `backlog/`), `/initlab:mc` (renders the dashboard), and confirm `/initlab:loop` / `/initlab:dispatch` / `/initlab:verify` exist.
4. **(Optional) the other hooks** — `PostToolUse`/`PreToolUse`/`Notification` go live in-session after `/reload-plugins`; `PreCompact` writes a checkpoint marker before a compaction. The `Notification`→Telegram nudge and the `PreToolUse` catastrophic-command guard only act when `way_of_working.remote != off` in the config.

**3. Clean up:**

```text
/plugin uninstall initlab@beebeeb-local
/plugin marketplace remove beebeeb-local
```

`rm -rf ~/initlab-smoke`. If skills/commands linger after a reinstall, clear the cache: `rm -rf ~/.claude/plugins/cache`.

## Commands (current)

- `/initlab` — front door: set up if needed, else show status and next actions.
- `/initlab:setup` — configure this project's way of working (guided per-axis wizard) and scaffold it.
- `/initlab:init` — scaffold the way of working into the current project (non-interactive; wizard's config is preserved).
- `/initlab:boot` — boot protocol: verify reality from disk, reconcile, then brief (wait for "go" before starting the loop).
- `/initlab:checkpoint` — write a SESSION_STATE checkpoint now so the next session can resume from it alone.
- `/initlab:upgrade` — reconcile this project's initlab files to the current plugin version (preserves your edits).
- `/initlab:doctor` — health-check this initlab project: drift, stale state, in-review cap.
- `/initlab:loop` — run the autonomous teamlead loop (pick → dispatch → verify-gate → never stop).
- `/initlab:task "<title>"` — create a task (allocates the next ID, renders the canonical format).
- `/initlab:dispatch <id> [lane]` — move a task to in-development and dispatch it to an engineer.
- `/initlab:verify <id>` — run a task's verification and gate it to verified/ (or back).
- `/initlab:mc` — Mission Control: a text dashboard of tasks, decisions, in-review cap, build, and prod.
- `/initlab:teamlead <topic>` — designate this session a topic lead; scopes task-picking to one `**Track:**` and locks tasks via `bb-coord` so multiple leads don't collide.
- `/initlab:inception` — scope-controlled product genesis for a greenfield project: an idea → a v1 spec + seeded backlog, refusing to proceed until you name what's explicitly OUT of v1.
- `/initlab:remote` — operate the project from your phone over the official Telegram Channels plugin: status + decisions, with an outbound nudge hook and a `PreToolUse` guard that blocks catastrophic commands.

## Tests

```sh
bash tools/initlab/test/all.sh
```
