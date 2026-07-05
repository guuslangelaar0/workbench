---
description: workbench front door — run the level-aware adoption wizard if needed, else show status and next actions
allowed-tools: ["AskUserQuestion", "Bash", "Read", "Write", "Edit", "Glob", "Grep"]
---

You are the workbench front door — **the entry point every new user should type first**, configured or not. `/workbench:setup` runs the same guided per-axis wizard directly, for later re-runs once someone already knows they want to reconfigure (e.g. change a maturity-level axis); it is not a separate first step. Decide what to do based on project state:

- If `${CLAUDE_PROJECT_DIR}/.workbench/config.json` does NOT exist -> this project isn't configured yet. Run the `setup` skill, which acts as the **level-aware adoption wizard**: it will assess the existing repo and git signals, give positive feedback on what's already in place, infer the current maturity level, recommend a target level, ask whether to enable Workbench hooks (**recommended**), then scaffold via `init.sh --level <chosen> --hooks <enabled|disabled>`. The wizard is the right first step for any new or existing project.
- If it DOES exist -> show the current status: run `/workbench:mc` (the dashboard) if available, else summarize task counts from `.claude/tasks/` and the SESSION_STATE "Now" snapshot. Then run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/hooks-mode.sh" status --target "${CLAUDE_PROJECT_DIR}"` and report whether Workbench hooks are enabled, disabled by choice, missing, or stale.
- If hook status is `missing` or `stale`, recommend enabling/updating hooks with `bash "${CLAUDE_PLUGIN_ROOT}/scripts/hooks-mode.sh" enable --target "${CLAUDE_PROJECT_DIR}"`. Explain that hooks let new sessions re-ground from disk, route normal chat into Workbench actions, keep lead purpose visible, surface mesh/team context, and checkpoint before compaction.
- If hook status is `disabled`, say slash commands still work, but the always-on behavior is disabled by choice after choosing to skip hooks. Offer to enable hooks.
- Offer the natural next actions: `/workbench:boot` (verify + brief), `/workbench:loop` (run the teamlead loop), `/workbench:inception` (greenfield genesis), `/workbench:setup` (reconfigure).

This is also intended as the fallback for any `/workbench:*` command run in an unconfigured project — not every command implements this defer-check yet; treat this doc as the front door to point users at manually when you notice a command running against an unconfigured project.

> **Power-user note:** `/workbench:setup` and `/workbench:init` remain explicit entry points for users who want setup-only or low-level scaffolding, but `/workbench:workbench` is the front door to remember (type `/workbench` to filter the command menu to it). It does the right thing automatically.
