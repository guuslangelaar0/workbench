# Lead Purpose Parking Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add durable lead purpose and task-first parking so leads keep one feature in focus and park unrelated discoveries into backlog.

**Architecture:** Store lead-purpose records as greppable shell-friendly files under `.workbench/leads/`. Keep parking as a thin wrapper over the existing `task-new.sh` lifecycle so parked work appears in Mission Control and the normal loop.

**Tech Stack:** Bash scripts, Claude Code command markdown, workbench hook JSON, markdown docs, shell tests.

## Global Constraints

- Use TDD: write failing shell tests before production scripts/hooks.
- Keep scripts pure bash/awk/sed; no `jq` dependency.
- Do not bump plugin version for feature work; write `[Unreleased]` changelog only.
- Preserve existing command and hook patterns.

---

### Task 1: Lead Purpose Storage

**Files:**
- Create: `test/lead-purpose.test.sh`
- Create: `scripts/lead.sh`

**Interfaces:**
- Produces: `scripts/lead.sh set|status|latest-open|clear --target DIR --session-id SID ...`

- [ ] Write tests for setting, reading, latest-open, and clearing a lead purpose.
- [ ] Run `bash test/lead-purpose.test.sh` and confirm it fails because `scripts/lead.sh` is missing.
- [ ] Implement `scripts/lead.sh` with greppable `key=value` files.
- [ ] Run `bash test/lead-purpose.test.sh` and confirm it passes.

### Task 2: Task-First Parking

**Files:**
- Create: `test/park.test.sh`
- Create: `scripts/park.sh`

**Interfaces:**
- Consumes: `scripts/task-new.sh`
- Produces: backlog task with a `## Parked origin` section.

- [ ] Write tests for parking a bug with origin session/task/purpose metadata.
- [ ] Run `bash test/park.test.sh` and confirm it fails because `scripts/park.sh` is missing.
- [ ] Implement `scripts/park.sh` as a wrapper around `task-new.sh`.
- [ ] Run `bash test/park.test.sh` and confirm it passes.

### Task 3: Hooks And Commands

**Files:**
- Modify: `hooks/hooks.json`
- Create: `hooks/bin/lead-purpose-nudge.sh`
- Modify: `hooks/bin/ground-session.sh`
- Create: `commands/lead.md`
- Create: `commands/park.md`
- Modify: `commands/teamlead.md`
- Modify: `commands/dispatch.md`
- Create: `skills/lead-purpose/SKILL.md`

**Interfaces:**
- Consumes: `scripts/lead.sh`
- Produces: `UserPromptSubmit` additional context and optional `sessionTitle`.

- [ ] Extend tests to cover the hook nudge output and syntax.
- [ ] Run focused hook tests and confirm they fail before hook implementation.
- [ ] Implement the hook and command surfaces.
- [ ] Run focused tests and confirm they pass.

### Task 4: Docs And Release Hygiene

**Files:**
- Modify: `README.md`
- Modify: `docs/commands.md`
- Modify: `docs/concepts.md`
- Modify: `CHANGELOG.md`
- Modify: `test/all.sh`

**Interfaces:**
- Produces: documented command reference and changelog entry.

- [ ] Add command/docs/changelog updates.
- [ ] Add new focused tests to `test/all.sh`.
- [ ] Run focused tests, `bash test/hooks.test.sh`, `bash test/command.test.sh`, `bash test/skills.test.sh`, and `bash scripts/validate-plugin.sh`.
