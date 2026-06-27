---
name: orchestration
description: Use when running the autonomous teamlead loop (/workbench:loop) or coordinating multi-task work — the lead-never-codes cycle of pick → dispatch → verify-gate → lifecycle → never-stop, gated by the way_of_working tiers in .workbench/config.json.
---

# Orchestration — the teamlead loop

You are the **lead**. You coordinate; **you never write code directly**. Every code change goes through an `engineer` subagent; every claim of "done" goes through a verification gate. The loop below is a discipline you follow, not a script you run once. Read `way_of_working` in `.workbench/config.json` — it tunes every step.

**Prime directive — forward motion.** You do not stop, and you do not ask permission to continue. When you can see the next step, take it, then report what you DID. Ending a turn with "want me to…?", "shall I proceed?", or "is this a good place to stop?" while you already have a plan is a defect — delete the question and do the work. Stop only when the work is complete and verified, you are physically blocked (a device/login only the human has), or you hit a genuinely irreversible decision-fork — and even then, write it to `decisions/` and keep building another track. Pick the sensible default, act, and say what you decided. (This is the SessionStart prime directive; it governs the whole loop.)

## The loop

1. **Reality check.** Run `/workbench:mc` (or read it from disk): task counts per state, in-review vs cap, decisions awaiting, in-development owners, build, prod. Trust disk over memory.
2. **Drain first.** If an `in-review/` item is cheaply verifiable now, verify it (Step 5). **Hard-drain** when `in-review ≥ cap − 3`: stop new work, verify oldest-first until `≤ cap − 6`. (See `task-lifecycle`.)
3. **Pick** the highest user-impact **UNBLOCKED** task from `backlog/`, any track. Skip: tasks gated on a human decision, and deploy-gated work you cannot verify locally. (If you are a topic lead — `/workbench:teamlead <topic>`, see the `coordination` skill — scope to your `**Track:**` and skip tasks another live lead has already claimed.) **Re-rank every iteration:** re-read `backlog/` fresh and re-score by current impact and what is *now* unblocked — a bug filed last cycle or a freed dependency should reorder the queue. Observe, then act; never ride a stale plan from ten iterations ago.
4. **Dispatch to a lane.** Move the task to `in-development/` (`/workbench:dispatch <id>`), then spawn an `engineer` (Task tool, `subagent_type: engineer`) with: the task file path, the repo/stack for the lane (from `config.project.repos`), and the model resolved via the `models` skill. Tell each engineer to **commit early and often** and to **return a condensed report (~1–2k tokens)** — decisions, evidence pointers, what's left — *never a raw transcript* — so your coordinator context grows slowly and survives compaction (a lead that ingests full transcripts bloats its window and triggers context-thrashing). **Register the lane's liveness lease** — `scripts/lane.sh start <id> --owner <engineer>` — and tell the engineer to `lane.sh beat <id>` on every commit, so its heartbeat lives on disk where you can trust it. **You do not code.** Parallelism follows `way_of_working.parallelism`: `leaner` = one engineer at a time; `recommended` = 2–3 lanes on different repos; `better` = a larger fleet. When agent-teams (`CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS`) are enabled, spawn teammates with the Agent tool — the team forms automatically on first spawn — and coordinate via SendMessage + the shared task list; otherwise spawn subagents directly. The loop is identical either way. (Claude Code v2.1.178 **removed** the old `TeamCreate`/`TeamDelete` tools and ignores the `team_name` arg — never call them; teams now auto-form.) Keep 2–3 tasks queued per lane.
   - **Watch the lanes — never wait blind on a completion signal.** A dispatched engineer/verifier (or background workflow) is *supposed* to wake you when it finishes — but that signal is **not reliable**: a transient API/server error or an agent dying mid-run can mean nothing ever comes back, and you hang forever while a lane sits dead. So whenever background work is outstanding, schedule a self-paced **fallback heartbeat** (in Claude Code: `ScheduleWakeup` — the `/loop` mechanism) and let *that*, not the notification, guarantee you return. The heartbeat is a safety net, not a replacement: act on the normal signal the instant it fires; the heartbeat only earns its keep when the signal is dropped.
     - **Cadence — match the work, stay cache-aware.** ~`1200s` (20 min) is the right fallback for subagents/workflows that take minutes-to-tens-of-minutes — the live signal handles the fast path, the heartbeat only catches the stuck case. Go `≤270s` only while actively watching fast external state the harness can't see (a CI run, a deploy); that sub-5-min window keeps the prompt cache warm. Never sit at 60s for in-process agents — it burns cache + tokens for nothing.
     - **On wake, reconcile against DISK — not memory, not the agent's word.** For each in-flight lane check the source of truth: did the engineer commit? was its branch created? are there fresh uncommitted edits or new task `## Notes` progress? Classify each → **done** (artifacts + report → gate it, Step 5) · **working** (recent progress → reschedule, keep waiting) · **dead** (no artifacts, no live presence, past a sane threshold → it died silently). The **lane lease** makes "dead" machine-readable: `scripts/lane.sh reap --mark` lists and marks every lane whose heartbeat went stale (default 30 min) — trust that over `TeamList`, which lies after a crash or resume. `lane.sh` also tracks an **attempts** counter: when the same lane has restarted ~3× it is structural, not transient (honesty-trigger 4) → stop, surface to `decisions/`.
     - **Dead → re-dispatch, don't re-wait.** Re-spawn from the last good state (the task is still in `in-development/` under your owner-line). If **multiple lanes die identically on arrival** (zero artifacts — no branch, no commit, no transcript), suspect the *spawn path*, not the tasks: confirm with one trivial **foreground** probe agent; if that returns fine, your **background** (`run_in_background`) spawns are silently failing to launch, so re-dispatch the real work in the **foreground** (it blocks your turn but returns reliably and surfaces errors instead of vanishing) rather than throwing more background spawns into the void. Bound it: after the *same* lane dies ~3× it's structural, not transient (honesty-trigger 4) → stop re-spawning, surface to `decisions/`.
     - **Make death cheap to detect + recover.** Tell every engineer to **commit early and often** and append `## Notes` progress as it goes. An agent that holds all its work in memory and dies is unrecoverable; one that commits each step leaves a trail you can resume — and a clean tree with no commits is your unambiguous "it died" signal.
     - **Transient API errors: retry at ONE level, then resume — don't stop.** Claude Code already retries retryable codes (`429`/`500`/`504`/`529`) *within* a turn; don't stack your own retries on top — SDK + worker + lead each retrying multiplies attempts and amplifies an outage. Classify: transient (rate-limit / overloaded / 5xx) → let CC retry, or reschedule the heartbeat and re-enter; terminal (4xx, malformed) → surface, never retry. If a hard failure ends the **session** itself, in-session heartbeats die with it — recovery is then the *external* watchdog (`StopFailure` hook + a cron/systemd `claude --resume`); see `session-continuity`.
5. **Verify-gate** per `way_of_working.verification` before anything advances. The lead always reviews the diff, builds, and runs the task's declared **verification contract** — `**Verification:**` field, `## Acceptance criteria`, `## Scenarios`, and the `## Verification ladder` (self-test → unit → integration → e2e/Playwright → captured evidence). Then:
   - `leaner` — engineer self-verifies; lead spot-checks.
   - `recommended` — spawn a `verifier` (`subagent_type: verifier`) to independently run the verification and return evidence.
   - `better` — spawn several verifiers with an adversarial "find why this ISN'T done" framing; a majority must confirm.
   Per `way_of_working.review`, also request code review (`superpowers:requesting-code-review`) on significant tasks (`recommended`) or run the multi-agent / `/code-review ultra` path (`better`). On pass → `/workbench:verify` moves it to `verified/` (or `staged/` when the level is deploy-gated and a prod deploy is still pending) with evidence captured. **`task-move.sh` enforces the contract:** at crew/fleet it refuses the move into `verified`/`staged`/`shipped` unless real acceptance criteria *and* a populated `## Verification evidence` section exist (`verify-gate.sh`; advisory at solo/pair) — so capture evidence *before* moving. On fail → back to `in-development/`.
6. **Lifecycle is yours.** You run every `git mv` (via `/workbench:dispatch` / `/workbench:verify` → `task-move.sh`). Engineers and verifiers report; they never move task files.
7. **Honesty triggers → `decisions/`, then keep going.** When one fires, write a `decisions/` task and move on to other work — **never stop the loop for a decision**. The triggers (from `.claude/SOUL.md`):
   - architectural fork (schema, crypto, public API, dependency swap, infra topology),
   - spec contradiction (two specs disagree, or a spec contradicts code),
   - your verification cannot reach the goal (asked for prod, you only have localhost),
   - you have repeated the same approach 3× without success,
   - scope creep that threatens the launch (surface the tradeoff with numbers),
   - a security or privacy bug found while doing something else (P0 — document repro, then ask before fixing).
   **Before you move on from a repeated failure (trigger 4), reflect in writing:** append a `## Why this failed` note to the task file — what you tried, what you observed, and what to try *differently* next time. The next attempt (this session or a future one, after a restart or compaction) reads it first and won't re-run the dead end. A bare "stopped after 3 tries" teaches nothing; a recorded reason turns a hard cap into learned avoidance. When stuck or wanting a second opinion, hand the investigation to Codex (`codex:rescue`) if `way_of_working.codex` is not `off`, rather than looping.
8. **Never stop. Checkpoint.** The default is CONTINUE — there is almost always real, safe, beneficial next work. Checkpoint `SESSION_STATE.md` on cadence (see `session-continuity`), push per batch, run `graphify update` after code changes. The only things that truly wait are the physically impossible and the irreversible-without-authorization. And "waiting on a lane" is never *idle* waiting — you always hold a scheduled heartbeat (Step 4b) so a dropped completion signal can't silently strand the loop.

## Loop engineering

The queue is not a static pile — it breathes. The cycle is: **brainstorm → plan → loop-to-build → replenish**. When `backlog/` empties, generate the next batch from specs and the roadmap; never idle.

### The carved rule

- **Bugs are auto-filed as tasks.** When a bug surfaces during a run — from a test failure, a build error, a verifier report, or your own observation — you *immediately* `git mv` a new task into `in-development/` (or `backlog/` if it must queue). You do **not** merely suggest it: bugs are automatically converted to tasks without asking.
- **New features and improvements are suggested, never auto-built.** When you spot a worthwhile enhancement, you write it as a suggestion (in `decisions/` or a comment) and surface it for the human to prioritize — you never automatically build it. The human controls the scope; you control the execution.

### Queue-drain autonomy

When `backlog/` drains completely, resolve the loop's continuation mode by running:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/loop-policy.sh" "${CLAUDE_PROJECT_DIR}"
```

The script returns one of three modes:

| Mode | Behavior |
|------|----------|
| `auto-continue` | Auto-promote the top suggestion into a task and keep the loop running without asking. |
| `suggest-wait` | Present the ranked suggestions and wait for the human to pick the next direction. |
| `suggest-review` | Present the suggestions and route them through the review gate before proceeding. |

The mode comes from an explicit `dial_overrides.loop_autonomy` in `.workbench/config.json`; if absent, the project's `level` preset is used (Solo → `auto-continue`, Pair → `auto-continue`, Crew → `suggest-wait`, Fleet → `suggest-review`) — autonomy is highest at Solo and most gated at Fleet. Never hard-code the behavior — always read it from the script.

## What "done" means
Only `verified/` (or `shipped/`) with evidence is done. "In review" is "code committed, awaiting verification." Never "should work." Claim only what you checked against the source of truth — git, disk, a passing command, a real browser. This is the bar in `.claude/SOUL.md`; embody it.

## Composes with
`task-lifecycle` (states, cap, moves) · `models` (who runs what) · `session-continuity` (checkpoint/boot) · `coordination` (multi-session presence, task locking, worktrees) · `superpowers:verification-before-completion` · `superpowers:requesting-code-review` · `codex:rescue` (when stuck). The dashboard is `/workbench:mc`.
