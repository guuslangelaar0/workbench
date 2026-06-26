---
name: upgrade
description: Use when running /workbench:upgrade — reconcile a project's workbench-generated files to the current plugin version, preserving user edits.
---

# workbench upgrade (reconcile)

Bring a project's generated files up to the current plugin version without clobbering the user's edits. This is intelligent migration — you read each file and decide, you don't blindly copy.

## Procedure
1. Run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/drift.sh" "${CLAUDE_PROJECT_DIR}"` to classify every managed file as `ok` / `edited` / `missing`, and note whether the plugin version advanced past the manifest's.
2. If the plugin version did NOT advance and nothing is `edited`/`missing`, report "already current" and stop.
3. For each managed file, act by its **mode** (from the manifest) and status:
   - **`managed` + ok** (mechanism file, user hasn't touched it — coord scripts, etc.): regenerate from the current plugin template/source. Safe overwrite.
   - **`managed` + edited**: the user changed a mechanism file. Show them the diff between their version and the freshly-regenerated one; ask before overwriting (warn-default — never clobber silently).
   - **`merge` + ok** (doc the user could edit but hasn't — CLAUDE.md, SOUL.md, task README, AGENTS.md): regenerate from the current template.
   - **`merge` + edited**: **semantically merge.** Read the user's current file AND the current template. Produce a merged version that KEEPS the user's project-specific content and customizations while pulling in the new way-of-working structure/sections from the template. Present the result (or a diff) for approval before writing. You do not need the old template — the `edited` status already tells you they customized it; reconcile current ⊕ new-template by meaning, not by mechanical 3-way.
   - **`once`** (SESSION_STATE, _next-id): never touch.
   - **`missing`**: offer to regenerate it.
4. After applying approved changes, re-stamp `.workbench/manifest.json`: update each touched file's `rendered_hash` to its new content hash and `from_version` to the current plugin version, and set top-level `plugin_version` to current.
5. Summarize what changed, what was preserved, and what you skipped.

## Rendering templates

When you regenerate a file from a template (any `managed` or `merge` file whose body comes from a `${CLAUDE_PLUGIN_ROOT}/templates/...tmpl`), read the token values from `.workbench/config.json` before rendering:

- `project.name` → `{{PROJECT_NAME}}`
- `project.mission` → `{{MISSION}}`
- `project.launch_target` → `{{LAUNCH}}`
- Build `{{REPO_MAP}}` from `project.repos` — a short bullet list of repo entries, or the literal string `(single repo)` if the array is empty or absent.

Never write a literal `{{TOKEN}}` into any project file. If a value is missing from `config.json`, ask the user rather than guessing or leaving the placeholder in place.

## Principles
- Default to preserving user content. When unsure, show a diff and ask.
- The manifest is the source of truth for mode; `drift.sh` for status. Re-stamp it so the next upgrade starts clean.
- Keep commits scoped; commit the reconcile as its own change.
