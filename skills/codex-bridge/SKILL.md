---
name: codex-bridge
description: Use when coordinating with Codex (a second coding agent) in a workbench project — /workbench:codex-engineer, the shared disk-based protocol, codex:rescue, and codex:setup.
---

# Codex bridge

Claude and Codex can work the same workbench project. Disk is the shared source of truth — Codex can't see Claude's in-memory team state, and vice versa.

- **Source of truth:** `CLAUDE.md`, `AGENTS.md`, `.claude/SESSION_STATE.md`, `.claude/tasks/`, `.claude/CODEX_COORDINATION.md` (the shared operating agreement). Read them before non-trivial work.
- **Native Workbench Codex engineer lane:** use `/workbench:codex-engineer <task-id>` when the user explicitly asks for Codex, when a task needs an independent Codex implementation pass, or when `way_of_working.codex` is `full-lane`. This command keeps Workbench as the lead/lifecycle owner and invokes the OpenAI Codex plugin through `subagent_type: "codex:codex-rescue"`.
- **Fallback rescue:** use `/codex:rescue` directly only when you are outside a Workbench task lifecycle or need a one-off Codex diagnosis. Use `/codex:setup` if the OpenAI Codex plugin is unavailable or unauthenticated.
- **Ownership:** before editing, check `git status` + the task file; claim via the task's `## Notes` owner line and `wb-coord claim`. Keep commits scoped so parallel agents don't sweep each other.
- **Codex as teamlead:** the generated `codex-teamlead-prompt` (rendered into the project when codex is enabled) lets Codex run the coordinator loop with the same lifecycle + honesty rules.
