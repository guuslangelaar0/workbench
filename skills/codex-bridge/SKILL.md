---
name: codex-bridge
description: Use when coordinating with Codex (a second coding agent) in a workbench project — the shared disk-based protocol, codex:rescue, and codex:setup.
---

# Codex bridge

Claude and Codex can work the same workbench project. Disk is the shared source of truth — Codex can't see Claude's in-memory team state, and vice versa.

- **Source of truth:** `CLAUDE.md`, `AGENTS.md`, `.claude/SESSION_STATE.md`, `.claude/tasks/`, `.claude/CODEX_COORDINATION.md` (the shared operating agreement). Read them before non-trivial work.
- **Handing work to Codex:** use `codex:rescue` to delegate a stuck investigation, a second-opinion diagnosis, or a substantial coding task to Codex through the shared runtime. Use `codex:setup` to check Codex is ready.
- **Ownership:** before editing, check `git status` + the task file; claim via the task's `## Notes` owner line and `wb-coord claim`. Keep commits scoped so parallel agents don't sweep each other.
- **Codex as teamlead:** the generated `codex-teamlead-prompt` (rendered into the project when codex is enabled) lets Codex run the coordinator loop with the same lifecycle + honesty rules.
