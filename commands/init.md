---
description: Scaffold the workbench way of working into the current project
allowed-tools: ["Bash", "Read", "AskUserQuestion"]
argument-hint: "[--name <name>] [--mission <m>] [--launch <date>] [--level solo|pair|crew|fleet] [--profile minimal|full]"
---

Scaffold the current project with the workbench way of working (task lifecycle, CLAUDE.md, config, manifest). This is the non-interactive scaffolder; for the guided experience (which chooses the level and every way-of-working axis for you) prefer `/workbench:setup`.

Steps:
1. Parse `$ARGUMENTS`. If `--name` is not present, ask the user for the project name (and optionally a one-line mission and a launch target).
2. **Determine the level.** If `.workbench/config.json` already exists, `init.sh` preserves the configured level — don't pass `--level`. Otherwise, if `--level` was not given, **ask the user which maturity level fits** (`solo` / `pair` / `crew` / `fleet` — see the `levels` skill) rather than relying on the default. ⚠️ Without `--level`, `init.sh` defaults to **`fleet`** (and `--profile full`), which creates the heaviest set of lifecycle stages — usually not what a new solo project wants.
3. Run the scaffolder with your Bash tool, passing the gathered values and targeting this project:
   `bash "${CLAUDE_PLUGIN_ROOT}/scripts/init.sh" --name "<name>" --level "<level>" [--profile minimal|full] [--mission "<m>"] [--launch "<date>"] --target "${CLAUDE_PROJECT_DIR}"`
4. After it completes, summarize what was created (it prints the actual `.claude/tasks/` lifecycle dirs for the chosen level, `CLAUDE.md`, and `.workbench/config.json` + `manifest.json`) and tell the user the next step: configure the way-of-working axes with `/workbench:setup`, or set up session continuity. If `init.sh` reports any **preserved** files (it never overwrites files that already exist), pass that along and point the user at `/workbench:upgrade` to reconcile them.

Do not run the scaffolder until you have a project name (and a level for a new project).
