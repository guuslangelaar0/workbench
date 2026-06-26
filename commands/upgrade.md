---
description: Reconcile this project's workbench files to the current plugin version (preserves your edits)
allowed-tools: ["Bash", "Read", "Edit", "Write", "Grep", "Glob"]
---

Run the workbench upgrade reconcile for this project using the `upgrade` skill: classify drift via `drift.sh`, then per-file act by mode — regenerate untouched mechanism/doc files, semantically merge edited docs (preserving the user's content), never touch `once` files, and ask before overwriting edited `managed` files. Re-stamp `.workbench/manifest.json` afterward and summarize.
