---
description: Safely remove workbench-managed project files using .workbench/manifest.json
allowed-tools: ["Bash", "Read", "AskUserQuestion"]
argument-hint: "[--dry-run] [--apply] [--keep-data] [--force]"
---

Run the project-level workbench uninstall. This is separate from `/plugin uninstall workbench@workbench`, which only removes the Claude plugin from Claude Code.

Default to dry-run:

!`bash ${CLAUDE_PLUGIN_ROOT}/scripts/uninstall.sh --target "$CLAUDE_PROJECT_DIR" --dry-run`

If the user explicitly confirms applying the plan, run the same script with `--apply` and any user-provided flags. Preserve `merge`, `once`, pre-existing, and edited files unless the user explicitly asks for destructive cleanup.
