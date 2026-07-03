---
description: Directly (re-)run the guided per-axis setup wizard — use when you already know you want to configure or reconfigure this project's way of working. New to this project? Run /workbench:workbench instead.
allowed-tools: ["AskUserQuestion", "Bash", "Read", "Write", "Edit"]
---

This is the **direct/explicit entry point** to the setup wizard — for when you already know you want to run or re-run it, e.g. to change a maturity-level axis (models, verification, review, ...) later. It is not the recommended first stop for a brand-new user: on an unconfigured project, `/workbench:workbench` (the front door) runs this exact same wizard plus assessment and status framing, so most people should type that first. If you are not sure what you need, run `/workbench:workbench`; it will route here when setup or reconfiguration is the right next step.

Run the workbench setup wizard for this project. Use the `setup` skill: walk the configuration axes one at a time as `AskUserQuestion` cards (Recommended first, with Better/Leaner + cost notes), ask whether to enable Workbench hooks (Recommended) or skip them (less benefit; slash commands still work), write `.workbench/config.json`, then scaffold via `init.sh --hooks <enabled|disabled>`.

If `.workbench/config.json` already exists, confirm whether the user wants to reconfigure. Re-running is safe: `init.sh` only writes files that are missing and never overwrites an existing CLAUDE.md/AGENTS.md/SOUL.md/coord script. Use `/workbench:upgrade` to reconcile existing files against current templates.
