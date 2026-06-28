# Loop hardening — making `/workbench:loop` survive the long run

**Status:** Proposal (awaiting prioritization)
**Date:** 2026-06-27
**Owner:** Guus
**Surfaces touched:** `skills/orchestration`, `skills/session-continuity`, `commands/loop.md`, `hooks/` (SessionStart/PreCompact/SubagentStop), `scripts/` (new: agent-liveness, loop-charter), task template (`**Verification:**` block), `/workbench:doctor`.

---

## 1. Why

The autonomous loop is the heart of workbench, and Claude Code's primitives already make it *good*. But "runs for hours/days without a human and is still making **real** progress when they return" is a much higher bar than "runs." The failure modes below are the ones that quietly turn a long run into wasted wall-clock or, worse, confident-but-false progress. They were raised from lived experience and corroborated against the production-grade patterns the orchestration world already settled on (Temporal, Kubernetes, Erlang/OTP, SRE, and the recent agent-eval literature — see [§7 References](#7-references)).

The through-line: **a long-running orchestrator must never trust its own memory.** Everything load-bearing — what the goal is, which workers are alive, what counts as done — has to be reconciled against ground truth each iteration, because over hours the in-memory belief *will* drift from reality (context rot, crashes, compaction).

---

## 1.5 The core mechanism: an external supervisor (why prose isn't enough)

**Instructions cannot fix the loop.** A directive in `SOUL.md`/`CLAUDE.md` ("never stop", "re-check liveness") only runs while the agent is alive and executing. The three worst failures happen precisely when it *isn't*: the process died on an API error (it can't read "resume yourself"), the context drifted/compacted (it no longer believes the instruction), or it's wedged. **A thing cannot supervise itself.** Self-referential prose is the weakest possible mechanism for the strongest failures.

The fix is to **invert the control structure.** Today the loop is *one long-lived agent told to never stop* — fragile: it dies with its process, rots with its context, and has no watcher. Replace it with:

> **A small, dumb, near-bulletproof external supervisor that owns the loop's liveness, and an agent that is a (mostly) stateless worker it invokes per iteration against durable disk state.**

This is the pattern every durable system already uses — Erlang/OTP supervisors, Kubernetes controllers, Temporal workers — applied to an agent loop. The supervisor is plain bash under `cron`/`systemd`/`tmux` (no LLM, ~nothing to crash). Each **tick** it:

1. **Reconciles disk state** — reap dead lanes (stale `.lane` heartbeats), read the charter + `in-development/` + `in-review` count + `SESSION_STATE.md`.
2. **Launches/relaunches a FRESH agent** — `claude -p --resume <sid>` (or a fresh session) with a **state-aware re-entry prompt built from disk**: "charter = X; in-dev tasks Y whose lanes died → re-dispatch; in-review at cap → drain first."
3. **Detects the deaths the agent can't fix from inside:** process exit (crash / API outage) → backoff + relaunch; **stall** (git HEAD and `SESSION_STATE.md` haven't advanced in N minutes → kill + relaunch); restart-intensity / budget exhaustion → **escalate to the human** (push), don't thrash.

Why this dissolves the failures instead of papering over them:

| Failure | Why prose fails | Why the supervisor fixes it |
|---|---|---|
| Servers down → loop stops | dead process can't obey "resume" | external process relaunches it on backoff |
| Phantom teammates | stale in-memory registry | fresh context each tick + lane reconciliation from disk |
| Context lost / too large | the goal got summarized away | the agent never runs long enough to rot; **disk is the state**, re-grounded every tick |
| Wedged / repeating | it can't tell it's stuck | external stall-detector (no HEAD movement) kills + restarts |

**The novel part for workbench:** the supervisor isn't a generic watchdog — it is **stateful over workbench's file-based control plane.** The git-tracked file tree (`tasks/`, `.workbench/lanes/`, `loop-charter.md`, `SESSION_STATE.md`) *is* the durable workflow state — workbench's equivalent of Temporal's event history — and the supervisor is a thin engine that drives **ephemeral, replaceable agent contexts** against it. Fresh agent per tick ⇒ no drift; durable external supervisor ⇒ no death; reconcile-from-disk ⇒ no phantoms. The in-agent prose (charter, prime directive, Reflexion) is the *within-a-tick* behavior; the supervisor guarantees *across-tick* continuity. **Both are needed, but the supervisor is the spine** — which is why P0-5 is elevated from "self-heal footnote" to the centerpiece: `scripts/watchdog.sh` (the supervisor) + a `/workbench:supervise` front door, layered as:

1. **In-session heartbeat** (`ScheduleWakeup`) — handles idle-but-alive. Weakest; dies with the session. *(have)*
2. **Stop/StopFailure hooks** — record state + write a recovery marker on turn-end/error. *(P0-5 hook, building)*
3. **External supervisor** — survives session death, relaunches, detects stall, escalates. **The spine.** *(P0-5, elevated)*

## 2. What workbench already does (the honest baseline)

We are not starting from zero. The current `orchestration` skill and continuity hooks already implement a meaningful chunk of the hardening:

- **Reality-check-first each iteration** — `/workbench:mc`, "trust disk over memory" (skill step 1).
- **Heartbeat fallback** — after dispatching background work, schedule a `ScheduleWakeup` so a dropped completion signal or a silently-dead agent can't strand the loop (step 4b).
- **Reconcile-against-disk + re-dispatch dead lanes** — on wake, classify each lane done/working/dead by *artifacts on disk* (commits, branch, `## Notes`), and re-spawn the dead (step 4b).
- **Commit-early-and-often mandate** so a dying agent leaves a resumable trail (step 4b).
- **Verify-gate tiers** — `leaner`/`recommended`/`better`, with adversarial "find why this ISN'T done" verifiers at the top tier (step 5).
- **Continuity hooks** — `PreCompact` checkpoint, `SessionStart` re-ground, `SESSION_STATE.md` handoff.
- **Honesty triggers → `decisions/`, never stop** (step 7), incl. the "repeated 3× = stop" rule (Trigger 4).
- **5-day session cap** — periodic restart-from-disk, which the research validates as the antidote to context rot.

So this proposal is about **closing specific gaps**, not rebuilding. Each gap below names what exists, what's missing, and the concrete change.

---

## 3. Failure-mode taxonomy → mitigations

Six categories. Each: the **symptom** (in plain terms), the **root cause**, the **proven mitigation** (cited), and the **concrete workbench change**.

### A. Phantom teammates — the registry outlives the workers

- **Symptom:** "On a next loop it still thinks the agents are there but they aren't." After an API error / server outage kills subagents, `TeamList` (or the lead's memory) still lists them; the lead dispatches into the void.
- **Root cause:** liveness is inferred from an *in-memory belief*, not from a fresh signal. This is the single most classic distributed-systems bug.
- **Proven mitigation — liveness by lease/timeout, never by belief.** Temporal doesn't detect worker death directly; it relies on a **heartbeat + start-to-close timeout** — a worker that stops heartbeating is timed out and its work retried ([Temporal activity-execution](https://docs.temporal.io/activity-execution)). Kubernetes infers node liveness from a renewed `renewTime` **Lease** timestamp; a stale lease = presumed dead ([K8s Leases](https://kubernetes.io/docs/concepts/architecture/leases/)), and liveness probes kill *running-but-stuck* containers ([K8s probes](https://kubernetes.io/docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes/)). Erlang/OTP supervisors restart a dead child to a **known-good initial state**, with a **restart-intensity cap** that breaks crash-loops ([OTP supervision](https://www.erlang.org/doc/system/sup_princ.html)).
- **Workbench change (P0):**
  1. **Lane heartbeat files.** Each dispatched engineer/verifier owns `.workbench/lanes/<task-id>.lane` — a tiny JSON it `touch`es on spawn, on every commit, and on each `## Notes` append. The lead never reads `TeamList` as truth; it reads lane-file **mtime**. Stale beyond a threshold (default 2× the expected step time) = **presumed dead → re-dispatch**, exactly the lease pattern. This upgrades step 4b's "reconcile on wake" from heuristic to a defined liveness contract.
  2. **Boot-time registry reconciliation.** `/workbench:boot` and the `SessionStart` hook diff the *believed* team (any persisted lane files) against reality (live presence + recent disk artifacts) and **garbage-collect stale lanes before the loop's first pick** — so a restarted session never inherits phantoms. Mirrors the CLAUDE.md session-hygiene "phantom team members" note, made mechanical.
  3. **Restart-intensity cap** (OTP): after the *same* lane dies N× (default 3) it's structural, not transient → stop re-spawning, surface to `decisions/`. (Step 4b already says ~3×; formalize it as a counter in the lane file.)
- **Claude Code reality (v2.1.178+, [agent-teams docs](https://code.claude.com/docs/en/agent-teams.md)):** there is **no liveness/heartbeat API** for teammates, and the phantom problem is *officially documented* — "`/resume` and `/rewind` do not restore in-process teammates… the lead may attempt to message teammates that no longer exist." The team config (`~/.claude/teams/session-*/config.json`) is **deleted on session exit**, but the task list (`~/.claude/tasks/session-*/`) **persists**. So our disk-first reconciliation is exactly right; CC gives us two native hooks to lean on: **`SubagentStart`/`SubagentStop`** (maintain a live-lane registry as agents come and go) and the documented mitigation of a **`SessionStart(resume)`** reminder to verify the task list and re-spawn rather than trust memory. The lane-file mechanism (1) is still worth it as a portable, agent-teams-independent liveness contract (it works for plain `subagent_type` dispatch too, not just experimental teams).
- **⚠️ Correctness fix (P0):** the `orchestration` skill currently says "you may use **TeamCreate**/SendMessage." `TeamCreate`/`TeamDelete` **were removed in v2.1.178** (teams now auto-form when the first teammate is spawned; `team_name` is accepted but ignored). The skill instructs a tool that no longer exists — fix the wording to "spawn teammates with the Agent tool; the team forms automatically." (Verify against the installed `claude --version`.)

### B. Stops on a transient error — no self-heal after an outage

- **Symptom:** "Sometimes Claude servers are down, we get an API error and it stops."
- **Root cause:** transient (retryable) failures aren't distinguished from terminal ones, and there's no resume-after-outage path.
- **Proven mitigation — classify, back off, resume.** Retry only **transient** errors; never retry permanent/malformed ones ([Azure Retry pattern](https://learn.microsoft.com/en-us/azure/architecture/patterns/retry)). For Anthropic specifically, retry **429 / 500 / 504 / 529**, do **not** retry 400/401/403/404/413, and note errors can occur *mid-stream after a 200* ([Claude API errors](https://platform.claude.com/docs/en/api/errors)). Use **exponential backoff + full jitter** ([AWS backoff+jitter](https://aws.amazon.com/blogs/architecture/exponential-backoff-and-jitter/)) and a **circuit breaker** to fail-fast while the upstream is down ([Azure circuit breaker](https://learn.microsoft.com/en-us/azure/architecture/patterns/circuit-breaker)). Crucially, **retry at only one level** and under a **global retry budget** — SDK+worker+lead each retrying multiplies attempts (4³=64) and amplifies an outage into a meltdown ([Google SRE](https://sre.google/sre-book/addressing-cascading-failures/)).
- **Workbench change (P0/P1):**
  1. **Outage → heartbeat-resume, not stop (P0).** The `ScheduleWakeup` fallback is already our resume primitive. Make it explicit that an API/transient error is **caught and converted into a scheduled re-entry** (backoff cadence), not a stop. The loop's invariant becomes: *the only exits are complete-and-verified, physically-blocked, or irreversible-fork* — a server outage is none of those.
  2. **A documented retry/backoff policy in the skill (P1):** transient-vs-terminal table (Anthropic codes), backoff+jitter, **single-level retry**, and a per-run retry budget so a flapping upstream can't burn the whole token budget. Today the skill is silent on this; engineers and the lead each improvise.
  3. **Idempotent lifecycle steps (P1).** Every state-mutating step the loop performs — `git mv` task moves, commits, lane-file writes — must be **idempotent / safe to re-run**, so a resumed-after-crash iteration can't double-apply (the idempotency-key principle, [Stripe](https://docs.stripe.com/api/idempotent_requests)). Mostly true already (a `git mv` of an already-moved file is a no-op); audit `task-move.sh` and the verify gate to guarantee it, supporting CLAUDE.md's "one state change at a time, confirm each."
- **Claude Code reality ([headless](https://code.claude.com/docs/en/headless.md) / [hooks](https://code.claude.com/docs/en/hooks.md) docs):** CC **already retries transient API errors within a turn** (emits a `system/api_retry` event with `attempt`/`max_retries`/`retry_delay_ms`/`error` category). So the *intra-turn* backoff in change 2 is largely handled by the platform — the real gap is **after retries are exhausted**: in `-p`/headless mode the turn then ends and the **`StopFailure`** hook fires (matchers: `rate_limit`/`overloaded`/`server_error`/…), with **no decision control — a hook cannot self-resume the session.** And critically, **`ScheduleWakeup` session-crons die *with* the session** (and `ScheduleWakeup` isn't available to subagents at all). So our in-session heartbeat covers a *hung* loop but **not a hard-crashed one**. The documented self-heal is an **external watchdog**: a `StopFailure` hook writes a recovery marker + Telegram alert (extend the existing `notify.sh`), and an **external** cron/systemd timer (or a cloud **Routine**) polls the marker / a stale `SESSION_STATE.md` and relaunches `claude --resume <loop-session-id> -p "Recover the loop. Read SESSION_STATE.md."`. This is the missing piece for "servers were down and it never came back."

### C. Verification that doesn't actually verify — confident "done"

- **Symptom:** "Verification isn't completely done… to actually have it good you need requirements, different scenarios, initially tested with an agent, and preferably automated (tests, Playwright)."
- **Root cause:** "done" is often a self-report against a vague goal, not an execution-grounded check against explicit criteria — and self-grading is biased.
- **Proven mitigation — spec-first, execution-grounded, independently judged.**
  - **Acceptance-criteria first.** Define done *before* building (spec-driven development, e.g. [Spec Kit](https://github.com/github/spec-kit) — note: experimental).
  - **Run, don't claim.** Self-report is worth almost nothing — the canonical SWE-bench result was ~2% of real issues solved when measured by *running the repo's tests* ([SWE-bench](https://arxiv.org/abs/2310.06770)). Execution-grounded gates are the strongest layer; this is why our `cargo test` + Playwright-evidence rule matters.
  - **Independent / adversarial verifier, not self-grade.** LLM-as-a-judge agrees with humans >80% ([MT-Bench](https://arxiv.org/abs/2306.05685)); RLHF code critics beat human reviewers at bug-finding ([CriticGPT](https://arxiv.org/abs/2407.00215)); multi-agent debate cuts hallucination ([debate](https://arxiv.org/abs/2305.14325)). But **Self-Refine (same-model self-assessment) does *not* remove self-enhancement bias** ([Self-Refine](https://arxiv.org/abs/2303.17651)) — so the final gate must be a *different* agent, and CriticGPT shows critics themselves hallucinate, so **keep a human on the final verifier** for high-stakes work.
  - **Multiple scenarios, agreement signal.** Sample several paths / cases and use agreement ([self-consistency](https://arxiv.org/abs/2203.11171)).
- **Workbench change (P0 — highest user value):** turn `**Verification:**` from a one-liner into a **structured verification contract** in the task template, authored *before* dispatch:
  - **Acceptance criteria** — the bulleted, checkable "definition of done."
  - **Scenarios** — happy path + named edge/negative cases (not just one).
  - **Verification ladder** (run top-to-bottom, by task type): (1) engineer self-test → (2) automated unit tests → (3) integration → (4) **e2e / Playwright for any UI** → (5) human-readable **evidence** (command output, screenshot path, commit SHA) captured in the task's `## Verification evidence`.
  - **Verifier independence** — the agent that gates is never the agent that built it; at `better`, an adversarial panel must reach majority "done." (The skill already supports verifier tiers; this *forces* criteria + evidence to exist and makes independence a rule, not an option.)
  - A `/workbench:verify` change to **refuse to pass** a task whose acceptance criteria or evidence section is empty — making "verified" structurally impossible to fake.
- **Claude Code reality — enforce it with hooks, not just prose ([hooks docs](https://code.claude.com/docs/en/hooks.md)):** the strongest find. CC exposes two hooks that can *block* a premature "done" and feed the reason back to the agent:
  - **`TeammateIdle`** fires when a teammate is about to go idle; **exit 2 keeps it working** with stderr as feedback. A `teammate-idle-guard.sh` can refuse idle while the teammate's task sits in `in-review/` with no `## Verification evidence`.
  - **`TaskCompleted`** fires when a task is being marked complete and can **prevent completion** + feed an error back — the enforcement point for "no evidence ⇒ cannot complete."
  This turns the verification contract from a *convention the model might skip* into a *gate the harness enforces*. Ship these as optional scaffolded hooks (level-scaled — advisory at `solo`, enforcing at `crew`+). Caveat: the **`Stop` hook has an 8-consecutive-block cap** (CC overrides it after 8), so a verification gate must detect a stuck task and route it to `decisions/` rather than blocking forever.

### D. The loop forgets its north star — context loss & bloat

- **Symptom:** "A loop removed the initial context," "a loop becomes too large."
- **Root cause:** over many iterations the window grows, auto-compaction summarizes lossily, and the **goal can land in the lossy middle** of context. Recall is U-shaped — strong at the start/end, degrades in the middle, even for long-context models ([lost-in-the-middle](https://arxiv.org/abs/2307.03172)).
- **Proven mitigation — externalize the goal, re-ground from disk, isolate sub-agent context.** Write durable notes *outside* the window and pull them back (agentic memory / NOTES.md), use just-in-time retrieval, and on compaction explicitly preserve goal + key decisions ([Anthropic context engineering](https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents)). Sub-agents work in clean windows and return condensed summaries so the lead stays lean; persist the plan to external memory and hand off to fresh contexts as limits approach ([Anthropic multi-agent](https://www.anthropic.com/engineering/built-multi-agent-research-system)). MemGPT formalizes paging context↔external store ([MemGPT](https://arxiv.org/abs/2310.08560)).
- **Workbench change (P1):**
  1. **A durable loop charter** — `.workbench/loop-charter.md` (≤1 page): the goal, hard constraints, and "definition of done" for *this* run. The `SessionStart` hook **re-injects it verbatim every session**, and the `PreCompact` hook guarantees it survives compaction. This is the always-pinned north star, placed at a context edge (not the lossy middle). Distinct from `SESSION_STATE.md` (which is volatile progress); the charter is the stable goal.
  2. **Lead stays lean by construction** — codify "engineers/verifiers return a condensed report, never raw transcripts" (the skill implies it; make it explicit + bounded, ~1–2k tokens), so the coordinator's context grows slowly.
  3. **Checkpoint-before-compact discipline** — already present; ensure the charter + open-lane state are in the `PreCompact` payload.
- **Claude Code reality — the exact wiring exists ([hooks](https://code.claude.com/docs/en/hooks.md) / [context-window](https://code.claude.com/docs/en/context-window.md) docs):** (a) **`PreCompact`** (matchers `auto`/`manual`) runs *synchronously before* compaction — flush charter + lane state there (our `precompact-checkpoint.sh` already does the SESSION_STATE half). (b) **`SessionStart`** fires again with **`source: "compact"`** after compaction and with `"resume"` on resume — hook it to **re-inject the charter as `additionalContext`** (our `ground-session.sh` is the place). (c) a **`## Compact Instructions`** section in the scaffolded CLAUDE.md is a *documented* lever telling the summarizer what to preserve (task IDs, last commit SHA, open decisions) — add it to the template. (d) **`FileChanged`** can re-inject an updated `SESSION_STATE.md`/charter when it changes. Also note the documented **context-thrashing** failure: if one huge tool output refills the window after each summary, CC stops auto-compacting and errors — so the charter must stay small and lane reports must be condensed (change 2).

### E. The loop runs a stale plan — doesn't re-prioritize

- **Symptom:** "Sometimes a loop doesn't dynamically update."
- **Root cause:** the loop follows the plan it started with instead of re-deriving the best next action from current state.
- **Proven mitigation — observe-then-act each step, with bounded search.** Ground each step in fresh observations rather than a fixed script ([ReAct](https://arxiv.org/abs/2210.03629)); when blocked, **backtrack and try a different branch** instead of re-committing to the stuck line ([Tree of Thoughts](https://arxiv.org/abs/2305.10601)).
- **Workbench change (P1):** make **re-ranking explicit** in the loop: each iteration re-reads `backlog/` and re-scores by current impact / unblocked-ness (the skill says "pick highest-impact unblocked" but doesn't say *re-evaluate every iteration* — state it, so newly-filed bugs and freed blockers reorder the queue). Tie to the existing **replenish** rule (brainstorm→plan→loop→replenish) so the queue "breathes."

### F. Stall / repeated-failure — spinning without progress

- **Symptom:** burning iterations re-trying the same failing approach, or making busywork that looks like progress.
- **Root cause:** no memory of *why* the last attempt failed, so the next attempt repeats it.
- **Proven mitigation — Reflexion.** After a failed attempt, write a **verbal self-reflection to an episodic memory buffer**; later attempts read it and avoid the same path (91% pass@1 on HumanEval) ([Reflexion](https://arxiv.org/abs/2303.11366)). Pair with hard step/turn caps that **degrade gracefully to a human handoff** rather than throwing ([CrewAI max_iter](https://docs.crewai.com/concepts/agents), [AutoGen termination](https://microsoft.github.io/autogen/stable/user-guide/agentchat-user-guide/tutorial/termination.html)).
- **Workbench change (P2):** upgrade Trigger 4 from "stop after 3×" to **Reflexion-style**: before moving laterally, the lead appends a `## Why this failed` note (what was tried, what was observed, what to try differently) to the task file. The next attempt — by this session or a future one — reads it first. Turns a hard cap into a *learned* avoidance and leaves an audit trail.

---

## 4. Proposed work, prioritized

A concrete, checkable backlog. P0 = directly addresses a named pain and is high-leverage; P1 = strong hardening; P2 = polish.

**P0**
- [ ] **Correctness fix:** remove the stale `TeamCreate`/`TeamDelete` instruction from the `orchestration` skill (removed in CC v2.1.178 — teams auto-form on first spawn). *(Cat. A)* — cheapest, ship first.
- [ ] **Verification contract** in the task template + `/workbench:verify` enforcement, **enforced by `TaskCompleted`/`TeammateIdle` hooks** (acceptance criteria + scenarios + verification ladder + evidence; block "done" on empty criteria/evidence; level-scaled). *(Cat. C)*
- [ ] **Lane heartbeat files + lease-based liveness** + a `scripts/lane.sh` helper; lead reconciles by mtime, not memory. Pair with **`SubagentStart`/`SubagentStop`** hooks for a live registry. *(Cat. A)*
- [ ] **Boot-time registry reconciliation** — `SessionStart(resume)` hook + `/workbench:boot` GC stale lanes before the first pick. *(Cat. A)*
- [x] **External supervisor — the spine** (§1.5). `scripts/watchdog.sh` (run by cron / `systemd --user` / tmux) + `/workbench:supervise` front door: relaunches a fresh `claude --resume` on crash (a `StopFailure` recovery marker) or stall (`SESSION_STATE.md` stale past `--max-idle`), reaps phantom lanes (`lane.sh reap --mark`) before handing over, and re-enters via `/workbench:boot` (state-aware reconcile from the charter + disk). Dry-run by default; `--exec` to act. Fed by `hooks/bin/stopfailure-recover.sh`. **Still open (P-next):** git-HEAD stall signal (beyond SESSION_STATE mtime), restart-intensity backoff/escalation in the supervisor loop itself, and a `--loop` continuous foreground mode. *(Cat. B)*

**P1**
- [ ] **Retry/backoff policy** note in the skill — but scoped correctly: CC already retries transient codes intra-turn (`api_retry`); document the *single-level retry + retry budget* discipline and the after-exhaustion resume path. *(Cat. B)*
- [ ] **Idempotency audit** of `task-move.sh` + verify gate. *(Cat. B)*
- [ ] **Durable loop charter** (`.workbench/loop-charter.md`) re-injected at `SessionStart(compact|resume)`, preserved at `PreCompact`; add a `## Compact Instructions` block to the scaffolded CLAUDE.md. *(Cat. D)*
- [ ] **Explicit per-iteration re-ranking** + replenish wording in the skill. *(Cat. E)*
- [ ] **Bounded condensed sub-agent reports** rule (keep the lead lean; avoid context thrashing). *(Cat. D)*

**P2**
- [ ] **Reflexion failure notes** (Trigger 4 upgrade): `## Why this failed` before lateral move. *(Cat. F)*
- [ ] **Restart-intensity counter** in the lane file (formalize the 3× cap; mind the Stop-hook 8-block ceiling). *(Cat. A/F)*
- [ ] **`/workbench:doctor` loop-health check** — phantom lanes, stale charter, in-review over cap, missing acceptance criteria.

---

## 5. Open decisions (for Guus)

1. **Lane liveness mechanism.** Heartbeat *files* (`.workbench/lanes/*.lane`, simple, git-ignored, works without agent-teams) vs. CC-native `SubagentStart`/`SubagentStop` hooks + the persisted task list. **Resolved by the CC research:** there is *no* liveness API and the phantom problem is documented, so files + Subagent hooks together are the right call — files give a portable lease that works for plain subagent dispatch (not just experimental teams), hooks keep the registry live. Recommendation: build both.
2. **How hard should `/workbench:verify` gate?** Strict (refuse to pass without acceptance criteria + evidence — strongest, but adds friction at `solo`) vs. level-scaled (advisory at `solo`, enforced at `crew`+). Recommendation: level-scaled, via the `way_of_working.verification` dial.
3. **Charter vs. SESSION_STATE.** Keep them as two files (stable goal vs. volatile progress) or one with two sections? Recommendation: two files — different lifecycles, different lossiness needs.
4. **Scope of P0 vs. ship incrementally.** All four P0 items are independent; recommend shipping the **verification contract** first (highest user-named value), then liveness.

## 5.5 Future option: a cloud-resident loop (Claude Code Routines)

The local supervisor (§1.5) is right for a self-hosted loop on your own machine. For the day we want the loop to run **while the machine is off entirely**, Claude Code **Routines** ([docs](https://code.claude.com/docs/en/routines.md), research preview as of 2026-06) are the cloud path — marked down here, not built now.

What they are (confirmed from the doc): a saved prompt + repos + connectors that runs on **Anthropic-managed cloud infrastructure** ("keep working when your laptop is closed"), with triggers that are **scheduled** (presets or a cron via `/schedule update`; **minimum interval one hour**), **API** (POST to a per-routine `/fire` endpoint with a bearer token), or **GitHub events** (PR/release). Managed at `claude.ai/code/routines` or CLI `/schedule`; Pro/Max/Team/Enterprise with Claude Code on the web; daily run cap + subscription usage.

Why it is **not** a drop-in for the local supervisor (the load-bearing limits): each run **clones a GitHub repo and starts a FRESH session** on `claude/`-prefixed branches — it has **no access to your local working tree and cannot `--resume` your local session**, and the 1-hour floor is far coarser than a watchdog cadence. So a Routine can't supervise a local loop.

The fit, if we go cloud later: **move the whole loop cloud-side** against a *remote* repo — the git remote becomes the sync boundary (clone → work → push, no local files), a scheduled Routine is the heartbeat / relaunch, and API + GitHub triggers make it event-driven; secrets ride the environment's env vars and the network allowlist. The §1.5 supervisor *design* still holds — it just relocates to the cloud and resumes against the remote. (For a Claude-native **local** runtime alternative to cron/systemd, note **Desktop scheduled tasks** — the "Local" option — which run on your machine with local-file access.)

## 6. Non-goals

- A bespoke durable-execution engine (Temporal-style replay) — LLM steps are non-deterministic, so we snapshot state to disk rather than event-source/replay. The file-based task lifecycle + charter *is* our durable store.
- Auto-building features (the carved rule stands: bugs auto-file, features only suggest).

## 7. References

Distilled from a cited research pass (all URLs verified live). Durable state / liveness: Temporal [event-history](https://docs.temporal.io/encyclopedia/event-history) · [activity-execution](https://docs.temporal.io/activity-execution); [K8s probes](https://kubernetes.io/docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes/) · [K8s Leases](https://kubernetes.io/docs/concepts/architecture/leases/); [Erlang/OTP supervision](https://www.erlang.org/doc/system/sup_princ.html); [AWS Step Functions](https://docs.aws.amazon.com/step-functions/latest/dg/welcome.html); [LangGraph checkpointers](https://docs.langchain.com/oss/python/langgraph/checkpointers). Resilience: [AWS backoff+jitter](https://aws.amazon.com/blogs/architecture/exponential-backoff-and-jitter/) · [Google SRE cascading failures](https://sre.google/sre-book/addressing-cascading-failures/) · [Azure Retry](https://learn.microsoft.com/en-us/azure/architecture/patterns/retry) · [Azure Circuit Breaker](https://learn.microsoft.com/en-us/azure/architecture/patterns/circuit-breaker) · [Claude API errors](https://platform.claude.com/docs/en/api/errors) · [Stripe idempotency](https://docs.stripe.com/api/idempotent_requests). Verification: [SWE-bench](https://arxiv.org/abs/2310.06770) · [MT-Bench / LLM-as-judge](https://arxiv.org/abs/2306.05685) · [CriticGPT](https://arxiv.org/abs/2407.00215) · [self-consistency](https://arxiv.org/abs/2203.11171) · [multi-agent debate](https://arxiv.org/abs/2305.14325) · [Self-Refine](https://arxiv.org/abs/2303.17651) · [Spec Kit](https://github.com/github/spec-kit). Stall/loop: [Reflexion](https://arxiv.org/abs/2303.11366) · [ReAct](https://arxiv.org/abs/2210.03629) · [Tree of Thoughts](https://arxiv.org/abs/2305.10601) · [CrewAI](https://docs.crewai.com/concepts/agents) · [AutoGen termination](https://microsoft.github.io/autogen/stable/user-guide/agentchat-user-guide/tutorial/termination.html). Context: [lost-in-the-middle](https://arxiv.org/abs/2307.03172) · [MemGPT](https://arxiv.org/abs/2310.08560) · [Anthropic context engineering](https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents) · [Anthropic multi-agent system](https://www.anthropic.com/engineering/built-multi-agent-research-system).

**Claude Code mechanics** (v2.1.178+, all from official docs, folded into §3): [agent-teams (experimental; no liveness API; phantom documented; TeamCreate removed)](https://code.claude.com/docs/en/agent-teams.md) · [hooks (PreCompact, SessionStart, StopFailure, TeammateIdle, TaskCompleted, SubagentStart/Stop, Stop 8-block cap)](https://code.claude.com/docs/en/hooks.md) · [sessions / --resume](https://code.claude.com/docs/en/sessions.md) · [headless / api_retry](https://code.claude.com/docs/en/headless.md) · [context-window / compaction & thrashing](https://code.claude.com/docs/en/context-window.md) · [best-practices](https://code.claude.com/docs/en/best-practices.md) · [routines (cloud watchdog)](https://code.claude.com/docs/en/routines.md).

> **CC-mechanics pass: folded in.** The agent-teams findings are version-sensitive (v2.1.178 removed `TeamCreate`); verify against the installed `claude --version` before implementing §3.A's correctness fix.
