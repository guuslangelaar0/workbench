---
description: Status / overview / "where do things stand" / "what's the state" — the Mission Control dashboard (tasks, decisions, suggestions, spend, in-review cap, build, prod). Always route a status or overview request here; never hand-reconstruct it.
allowed-tools: ["Bash", "Read"]
argument-hint: "[--no-prod] [--no-build]"
---

Show the workbench Mission Control dashboard for this project.

Run it with your Bash tool and show the output verbatim:
`bash "${CLAUDE_PLUGIN_ROOT}/scripts/mc.sh" $ARGUMENTS`

It reads `.workbench/config.json` for the project name, level (lifecycle stages are derived from it), in-review cap, repos, and prod URLs. Useful flags: `--no-prod` (skip network health checks), `--no-build` (skip cargo/tsc). If the user asked about one specific task rather than overall status, read that task file under `.claude/tasks/` directly instead of running the dashboard.
