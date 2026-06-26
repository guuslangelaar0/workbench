---
description: Mission Control — a text dashboard of team, tasks, decisions, in-review cap, build, and prod health
allowed-tools: ["Bash", "Read"]
argument-hint: "[--no-prod] [--no-build]"
---

Show the initlab Mission Control dashboard for this project.

Run it with your Bash tool and show the output verbatim:
`bash "${CLAUDE_PLUGIN_ROOT}/scripts/mc.sh" $ARGUMENTS`

It reads `.initlab/config.json` for the project name, lifecycle states, in-review cap, repos, and prod URLs. Useful flags: `--no-prod` (skip network health checks), `--no-build` (skip cargo/tsc). If the user asked about one specific task rather than overall status, read that task file under `.claude/tasks/` directly instead of running the dashboard.
