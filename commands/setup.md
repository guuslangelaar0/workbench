---
description: Configure this project's way of working (guided per-axis wizard) and scaffold it
allowed-tools: ["AskUserQuestion", "Bash", "Read", "Write", "Edit"]
---

Run the initlab setup wizard for this project. Use the `setup` skill: walk the configuration axes one at a time as `AskUserQuestion` cards (Recommended first, with Better/Leaner + cost notes), write `.initlab/config.json`, then scaffold via `init.sh`. If `.initlab/config.json` already exists, confirm whether the user wants to reconfigure (re-running is safe — `init.sh` only writes files that are missing and never overwrites an existing CLAUDE.md/AGENTS.md/SOUL.md/coord script; use `/initlab:upgrade` to reconcile existing files against current templates).
