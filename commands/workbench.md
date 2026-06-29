---
description: workbench front door — run the level-aware adoption wizard if needed, else show status and next actions
allowed-tools: ["AskUserQuestion", "Bash", "Read", "Write", "Edit", "Glob", "Grep"]
---

You are the workbench front door. Decide what to do based on project state:

- If `${CLAUDE_PROJECT_DIR}/.workbench/config.json` does NOT exist → this project isn't configured yet. Run the `setup` skill, which acts as the **level-aware adoption wizard**: it will assess the existing repo and git signals, give positive feedback on what's already in place, infer the current maturity level, recommend a target level, and scaffold via `init.sh --level <chosen>`. The wizard is the right first step for any new or existing project.
- If it DOES exist → show the current status: run `/workbench:mc` (the dashboard) if available, else summarize task counts from `.claude/tasks/` and the SESSION_STATE "Now" snapshot. Then offer the natural next actions: `/workbench:boot` (verify + brief), `/workbench:loop` (run the teamlead loop), `/workbench:inception` (greenfield genesis), `/workbench:setup` (reconfigure).

This is also the auto-trigger: any `/workbench:*` command, when run in an unconfigured project, should defer to this front-door assessment and setup first.

> **Power-user note:** `/workbench:init` and `/workbench:setup` remain as explicit aliases for users who want to jump directly to scaffolding or configuration — but `/workbench:workbench` is the front door to remember (type `/workbench` to filter the command menu to it). It does the right thing automatically.
