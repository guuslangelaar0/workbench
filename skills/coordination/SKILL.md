---
name: coordination
description: Use when more than one Claude or Codex session is open on the same project, when running multiple topic leads, or before a shared-repo commit or deploy — the multi-session presence, task-locking, commit-safety, action-lock, and worktree model (A+B+C) backed by scripts/coord/.
---

# Multi-session coordination

Every Claude Code tab (and every Codex session) is an independent process that shares only the filesystem — there is no live supervisor that sees them all. Sessions coordinate through files under `.claude/locks/` at the project root: **runtime state, gitignored, never history.** The tooling lives in `scripts/coord/`. Principle: **look, don't ask** — read presence and claims from disk before acting.

## Presence (C) — who else is live
- `scripts/coord/bb-coord ping <label>` registers/refreshes this session's heartbeat (the PostToolUse hook auto-pings, throttled, so it costs ~nothing). Use a `<label>` like `lead:storage`.
- `scripts/coord/bb-coord who` lists live sessions (within the TTL); `bb-coord status` adds held locks, active claims, and the overlap check.
- A session is "live" only while it keeps pinging; a closed or crashed tab ages out.

## Task locking (multi-teamlead) — don't double-pick a task
When two or more leads run in one project, lock a task before you start it:
1. Check it's free: `bb-coord claims task:<id>` — exits 0 and names the holder if another live session claims it; exits 1 if free.
2. Claim it: `bb-coord claim task:<id>`, and add an owner line to the task's `## Notes` (`<UTC> — claimed by lead:<topic> (session <sid>)`).
3. Move it to `in-development/` — the file leaving `backlog/` is the second, durable signal.
Claim by the logical key `task:<id>` (not a path), so the claim survives the `git mv` between state dirs. A claim is live only while your session pings: if a lead dies mid-task, its claim lapses and another lead can reclaim the (still in-development) task. `/initlab:dispatch` does steps 1–3 for you. **The in-review cap is shared across all leads** — respect it project-wide.

## Topic leads — divide by Track
`/initlab:teamlead <topic>` designates this session the lead for one track: it sets your label to `lead:<topic>` and scopes your orchestration loop to backlog tasks whose `**Track:** <topic>` matches. Other tracks belong to other leads. Run several leads concurrently on different tracks/repos; `bb-coord who` shows who leads what — don't double-lead a track.

## Commit safety (B) — don't sweep a sibling's staged files
A git pre-commit guard (installed by `scripts/coord/install-hooks.sh`) warns when you make a **bulk** commit (the whole index) while another live session has uncommitted changes in the same repo. Default is warn-only; `BB_COORD_STRICT=1` makes it hard-block. The fix is always one of:
- commit only your files with an explicit pathspec: `git commit -- <path> [<path>...]`, or
- isolate in a worktree (below).
A scoped commit can't sweep foreign staged files, so it always passes the guard.

## Action locks (B) — serialize a dangerous shared action
`scripts/coord/with-lock.sh <name> -- <command>` globally serializes an action (deploy, migration, anything that must not run twice at once) across all sessions; the lock carries a heartbeat and auto-expires if the holder dies. Example: `scripts/coord/with-lock.sh deploy-prod -- <your deploy command>`.

## Worktrees (A) — true isolation for parallel code in ONE repo
When two sessions must both write code in the **same** repo, give each its own worktree+branch so their indexes never collide: `scripts/coord/bb-worktree.sh new <name> [repo]` (then `cd` into it), `list`, and `rm <name>`. This is the cleanest collision fix — prefer it over fighting the commit guard when work genuinely overlaps a repo.

## When to use which
- Different repos, different tracks → just `ping` + scoped-pathspec commits.
- Same repo, parallel code → **worktrees**.
- Shared serial action (deploy / migration) → **with-lock**.
- Dividing a backlog across leads → **/initlab:teamlead** + task **claims**.

State under `.claude/locks/` is gitignored runtime data — never commit it, and never rely on it surviving a reboot.
