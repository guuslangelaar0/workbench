---
description: Scaffold the workbench way of working into the current project
allowed-tools: ["Bash", "Read", "AskUserQuestion"]
argument-hint: "[--name <name>] [--mission <m>] [--launch <date>]"
---

Scaffold the current project with the workbench way of working (task lifecycle, CLAUDE.md, config, manifest).

Steps:
1. Parse `$ARGUMENTS`. If `--name` is not present, ask the user for the project name (and optionally a one-line mission and a launch target).
2. Run the scaffolder with your Bash tool, passing the gathered values and targeting this project:
   `bash "${CLAUDE_PLUGIN_ROOT}/scripts/init.sh" --name "<name>" [--mission "<m>"] [--launch "<date>"] --target "${CLAUDE_PROJECT_DIR}"`
3. After it completes, summarize what was created (the `.claude/tasks/` lifecycle dirs, `CLAUDE.md`, and `.workbench/config.json` + `manifest.json`) and tell the user the next step: configure the way-of-working axes with `/workbench:setup`, or set up session continuity. If `init.sh` reports any **preserved** files (it never overwrites files that already exist), pass that along and point the user at `/workbench:upgrade` to reconcile them.

Do not run the scaffolder until you have a project name.
