---
description: Reconcile this project's workbench files to the current plugin version (preserves your edits)
allowed-tools: ["Bash", "Read", "Edit", "Write", "Grep", "Glob"]
---

Run the deterministic classifier first:

!`bash ${CLAUDE_PLUGIN_ROOT}/scripts/upgrade.sh --target "$CLAUDE_PROJECT_DIR" --dry-run`

Then use the `upgrade` skill to reconcile per-file by mode — regenerate untouched mechanism/doc files, semantically merge edited docs (preserving the user's content), never touch `once` files, and ask before overwriting edited `managed` files. Re-stamp `.workbench/manifest.json` afterward and summarize.
