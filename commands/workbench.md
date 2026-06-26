---
description: initlab front door — set up if needed, else show status and next actions
allowed-tools: ["AskUserQuestion", "Bash", "Read", "Write", "Edit", "Glob", "Grep"]
---

You are the initlab front door. Decide what to do based on project state:

- If `${CLAUDE_PROJECT_DIR}/.initlab/config.json` does NOT exist → this project isn't set up. Run the `setup` skill (the guided wizard) now.
- If it DOES exist → show the current status: run `/initlab:mc` (the dashboard) if available, else summarize task counts from `.claude/tasks/` and the SESSION_STATE "Now" snapshot. Then offer the natural next actions: `/initlab:boot` (verify + brief), `/initlab:loop` (run the teamlead loop), `/initlab:inception` (greenfield genesis), `/initlab:setup` (reconfigure).

This is also the auto-trigger: any `/initlab:*` command, when run in an unconfigured project, should defer to setup first.
