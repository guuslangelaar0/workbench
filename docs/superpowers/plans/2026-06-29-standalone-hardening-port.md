# Standalone Workbench Hardening Port Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Port the workbench install-ledger, uninstall, upgrade-classifier, doctor, and self-test hardening into the standalone `guuslangelaar0/workbench` repository.

**Architecture:** Keep the standalone `0.2.0` maturity-ladder implementation intact. Extend `scripts/init.sh` to write a manifest v2 install ledger, then add deterministic maintenance entrypoints for uninstall, upgrade classification, doctor, and self-test. All behavior is verified through shell tests before implementation.

**Tech Stack:** Bash, Python 3 for JSON/report maintenance scripts, JSON Schema draft-07, existing `test/*.test.sh` shell suite.

## Global Constraints

- Work in `/home/guus/code/workbench`, the standalone GitHub repository.
- Preserve the standalone install flow: `/plugin marketplace add guuslangelaar0/workbench` or local `/plugin marketplace add /path/to/workbench`.
- Preserve `0.2.0` features: maturity levels, architecture backbone, loop-charter, benchmarking, marketplace validation, and the existing command surface.
- Project scaffold uninstall is separate from Claude plugin uninstall.
- Keep `bash test/all.sh` green.

---

### Task 1: Manifest v2 Install Ledger

**Files:**
- Modify: `scripts/init.sh`
- Modify: `templates/schemas/manifest.schema.json`
- Modify: `test/upgrade.test.sh`

**Interfaces:**
- Produces `.workbench/manifest.json` with `schema_version`, `plugin`, `files[]`, and `side_effects`.
- Uses existing scaffold modes: `managed`, `merge`, `once`.

- [x] Add failing tests for schema version, plugin object, file ledger fields, preexisting preservation, gitignore side effect, git hook side effect, and level-specific files.
- [x] Update manifest schema for v2.
- [x] Update `init.sh` to record action, preexisting, previous hash, rendered hash, template hash, and side effects.
- [x] Preserve existing manifests on rerun so a target project's ledger remains the source of truth until `/workbench:upgrade`.
- [x] Run `bash test/upgrade.test.sh`.

### Task 2: Upgrade Classifier

**Files:**
- Create: `scripts/upgrade.sh`
- Modify: `commands/upgrade.md`
- Modify: `skills/upgrade/SKILL.md`
- Modify: `test/upgrade.test.sh`

**Interfaces:**
- Consumes `.workbench/manifest.json` v2 and current plugin templates.
- Produces statuses: `ok`, `edited`, `missing`, `preexisting`, `template-changed`.

- [x] Add failing tests for fresh, edited, missing, preexisting, and template-changed classifications.
- [x] Implement `scripts/upgrade.sh --target DIR --dry-run`.
- [x] Wire `/workbench:upgrade` and the upgrade skill to run the classifier first.
- [x] Run `bash test/upgrade.test.sh`.

### Task 3: Project Uninstall

**Files:**
- Create: `scripts/uninstall.sh`
- Create: `commands/uninstall.md`
- Create: `test/uninstall.test.sh`
- Modify: `test/all.sh`
- Modify: `README.md`, `docs/getting-started.md`, `docs/commands.md`

**Interfaces:**
- Consumes `.workbench/manifest.json`.
- Removes unchanged owned `managed` files and workbench side-effect blocks.
- Preserves `merge`, `once`, preexisting, edited files, and data by default.

- [x] Add failing tests for dry-run, apply, edited-file preservation, merge/once preservation, hook block removal, gitignore cleanup, missing manifest refusal, and `--keep-data`.
- [x] Implement `scripts/uninstall.sh --target DIR --dry-run|--apply [--keep-data] [--force]`.
- [x] Add `/workbench:uninstall`.
- [x] Document scaffold uninstall versus Claude plugin uninstall.
- [x] Run `bash test/uninstall.test.sh`.

### Task 4: Doctor And Self-Test

**Files:**
- Create: `scripts/doctor.sh`
- Create: `scripts/self-test.sh`
- Create: `commands/self-test.md`
- Create: `test/doctor.test.sh`
- Create: `test/self-test.test.sh`
- Modify: `commands/doctor.md`
- Modify: `test/all.sh`

**Interfaces:**
- `scripts/doctor.sh --target DIR` reports config, manifest, drift, hooks, lanes, dependencies, tasks, and continuity.
- `scripts/self-test.sh` validates plugin JSON, marketplace JSON, shell syntax, `scripts/validate-plugin.sh`, and optionally `test/all.sh`.

- [x] Add failing tests for doctor output and edited drift.
- [x] Add failing tests for self-test wiring and root marketplace validation.
- [x] Implement scripts and commands.
- [x] Run focused tests.

### Task 5: Full Verification And Handover

**Files:**
- Inspect all changed files.

- [x] Run `bash test/all.sh`.
- [x] Run `bash scripts/self-test.sh`.
- [x] Inspect `git status --short`.
- [ ] Report changes, verification evidence, and Claude-only live checks.
