---
description: Configure this project's way of working (guided per-axis wizard) and scaffold it
allowed-tools: ["AskUserQuestion", "Bash", "Read", "Write", "Edit"]
---

This command is part of the `/workbench:workbench` onboarding flow. If you are not sure what you need, run `/workbench:workbench`; it will route here when setup or reconfiguration is the right next step.

Run the workbench setup wizard for this project. Use the `setup` skill: walk the configuration axes one at a time as `AskUserQuestion` cards (Recommended first, with Better/Leaner + cost notes), ask whether to enable Workbench hooks (Recommended) or skip them (less benefit; slash commands still work), write `.workbench/config.json`, then scaffold via `init.sh --hooks <enabled|disabled>`.

If `.workbench/config.json` already exists, confirm whether the user wants to reconfigure. Re-running is safe: `init.sh` only writes files that are missing and never overwrites an existing CLAUDE.md/AGENTS.md/SOUL.md/coord script. Use `/workbench:upgrade` to reconcile existing files against current templates.
