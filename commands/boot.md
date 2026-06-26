---
description: Boot protocol — verify reality from disk, reconcile, then brief
allowed-tools: ["Bash", "Read", "Glob", "Grep"]
---

Run the initlab boot protocol for this project. Do NOT start new work until the briefing is delivered.

**Phase 1 — Reality verification (look, don't act):**
1. Read `.claude/SESSION_STATE.md`, `CLAUDE.md`, `.claude/SOUL.md`, `.claude/tasks/README.md`.
2. List the task dirs and count per status. Note the in-review count vs the cap.
3. `git status` in the workspace root and each repo. Note uncommitted state.
4. Build/health check as appropriate for the stack (compile/tests). Report pass/fail with the first error.
5. If a prod target is configured in `.initlab/config.json`, check its health read-only.

**Phase 2 — Reconcile:** if the task dirs / `_next-id` / `.initlab/` are missing or drifted, note it. Run `/initlab:upgrade` if managed files are behind (once that exists).

**Phase 3 — Briefing (facts, not vibes):** deliver ~8 lines — deployment gap, build status per repo, task counts, top 3 priorities by ID, any new blockers not in SESSION_STATE. Then wait for "go" before starting the loop.
