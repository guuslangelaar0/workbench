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

### B. Stops on a transient error — no self-heal after an outage

- **Symptom:** "Sometimes Claude servers are down, we get an API error and it stops."
- **Root cause:** transient (retryable) failures aren't distinguished from terminal ones, and there's no resume-after-outage path.
- **Proven mitigation — classify, back off, resume.** Retry only **transient** errors; never retry permanent/malformed ones ([Azure Retry pattern](https://learn.microsoft.com/en-us/azure/architecture/patterns/retry)). For Anthropic specifically, retry **429 / 500 / 504 / 529**, do **not** retry 400/401/403/404/413, and note errors can occur *mid-stream after a 200* ([Claude API errors](https://platform.claude.com/docs/en/api/errors)). Use **exponential backoff + full jitter** ([AWS backoff+jitter](https://aws.amazon.com/blogs/architecture/exponential-backoff-and-jitter/)) and a **circuit breaker** to fail-fast while the upstream is down ([Azure circuit breaker](https://learn.microsoft.com/en-us/azure/architecture/patterns/circuit-breaker)). Crucially, **retry at only one level** and under a **global retry budget** — SDK+worker+lead each retrying multiplies attempts (4³=64) and amplifies an outage into a meltdown ([Google SRE](https://sre.google/sre-book/addressing-cascading-failures/)).
- **Workbench change (P0/P1):**
  1. **Outage → heartbeat-resume, not stop (P0).** The `ScheduleWakeup` fallback is already our resume primitive. Make it explicit that an API/transient error is **caught and converted into a scheduled re-entry** (backoff cadence), not a stop. The loop's invariant becomes: *the only exits are complete-and-verified, physically-blocked, or irreversible-fork* — a server outage is none of those.
  2. **A documented retry/backoff policy in the skill (P1):** transient-vs-terminal table (Anthropic codes), backoff+jitter, **single-level retry**, and a per-run retry budget so a flapping upstream can't burn the whole token budget. Today the skill is silent on this; engineers and the lead each improvise.
  3. **Idempotent lifecycle steps (P1).** Every state-mutating step the loop performs — `git mv` task moves, commits, lane-file writes — must be **idempotent / safe to re-run**, so a resumed-after-crash iteration can't double-apply (the idempotency-key principle, [Stripe](https://docs.stripe.com/api/idempotent_requests)). Mostly true already (a `git mv` of an already-moved file is a no-op); audit `task-move.sh` and the verify gate to guarantee it, supporting CLAUDE.md's "one state change at a time, confirm each."

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

### D. The loop forgets its north star — context loss & bloat

- **Symptom:** "A loop removed the initial context," "a loop becomes too large."
- **Root cause:** over many iterations the window grows, auto-compaction summarizes lossily, and the **goal can land in the lossy middle** of context. Recall is U-shaped — strong at the start/end, degrades in the middle, even for long-context models ([lost-in-the-middle](https://arxiv.org/abs/2307.03172)).
- **Proven mitigation — externalize the goal, re-ground from disk, isolate sub-agent context.** Write durable notes *outside* the window and pull them back (agentic memory / NOTES.md), use just-in-time retrieval, and on compaction explicitly preserve goal + key decisions ([Anthropic context engineering](https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents)). Sub-agents work in clean windows and return condensed summaries so the lead stays lean; persist the plan to external memory and hand off to fresh contexts as limits approach ([Anthropic multi-agent](https://www.anthropic.com/engineering/built-multi-agent-research-system)). MemGPT formalizes paging context↔external store ([MemGPT](https://arxiv.org/abs/2310.08560)).
- **Workbench change (P1):**
  1. **A durable loop charter** — `.workbench/loop-charter.md` (≤1 page): the goal, hard constraints, and "definition of done" for *this* run. The `SessionStart` hook **re-injects it verbatim every session**, and the `PreCompact` hook guarantees it survives compaction. This is the always-pinned north star, placed at a context edge (not the lossy middle). Distinct from `SESSION_STATE.md` (which is volatile progress); the charter is the stable goal.
  2. **Lead stays lean by construction** — codify "engineers/verifiers return a condensed report, never raw transcripts" (the skill implies it; make it explicit + bounded, ~1–2k tokens), so the coordinator's context grows slowly.
  3. **Checkpoint-before-compact discipline** — already present; ensure the charter + open-lane state are in the `PreCompact` payload.

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
- [ ] **Verification contract** in the task template + `/workbench:verify` enforcement (acceptance criteria + scenarios + verification ladder + evidence; refuse to pass on empty criteria/evidence). *(Cat. C)*
- [ ] **Lane heartbeat files + lease-based liveness** in the orchestration skill and a `scripts/lane.sh` helper; lead reconciles by mtime, not `TeamList`. *(Cat. A)*
- [ ] **Boot-time registry reconciliation** — `SessionStart` hook + `/workbench:boot` GC stale lanes before the first pick. *(Cat. A)*
- [ ] **Outage = scheduled re-entry, never stop** — make the transient-error→`ScheduleWakeup`-resume path explicit in the skill. *(Cat. B)*

**P1**
- [ ] **Retry/backoff policy** section in the orchestration skill (Anthropic transient codes, backoff+jitter, single-level retry, retry budget). *(Cat. B)*
- [ ] **Idempotency audit** of `task-move.sh` + verify gate. *(Cat. B)*
- [ ] **Durable loop charter** (`.workbench/loop-charter.md`) re-injected at `SessionStart`, preserved at `PreCompact`. *(Cat. D)*
- [ ] **Explicit per-iteration re-ranking** + replenish wording in the skill. *(Cat. E)*
- [ ] **Bounded condensed sub-agent reports** rule (keep the lead lean). *(Cat. D)*

**P2**
- [ ] **Reflexion failure notes** (Trigger 4 upgrade): `## Why this failed` before lateral move. *(Cat. F)*
- [ ] **Restart-intensity counter** in the lane file (formalize the 3× cap). *(Cat. A)*
- [ ] **`/workbench:doctor` loop-health check** — phantom lanes, stale charter, in-review over cap, missing acceptance criteria.

---

## 5. Open decisions (for Guus)

1. **Lane liveness mechanism.** Heartbeat *files* (`.workbench/lanes/*.lane`, simple, git-ignored, works without agent-teams) vs. relying on a future Claude Code team-liveness API if one exists. Recommendation: files now (portable, zero-dependency); adopt a native API later if it lands. *(Depends partly on the CC-mechanics research now running.)*
2. **How hard should `/workbench:verify` gate?** Strict (refuse to pass without acceptance criteria + evidence — strongest, but adds friction at `solo`) vs. level-scaled (advisory at `solo`, enforced at `crew`+). Recommendation: level-scaled, via the `way_of_working.verification` dial.
3. **Charter vs. SESSION_STATE.** Keep them as two files (stable goal vs. volatile progress) or one with two sections? Recommendation: two files — different lifecycles, different lossiness needs.
4. **Scope of P0 vs. ship incrementally.** All four P0 items are independent; recommend shipping the **verification contract** first (highest user-named value), then liveness.

## 6. Non-goals

- A bespoke durable-execution engine (Temporal-style replay) — LLM steps are non-deterministic, so we snapshot state to disk rather than event-source/replay. The file-based task lifecycle + charter *is* our durable store.
- Auto-building features (the carved rule stands: bugs auto-file, features only suggest).

## 7. References

Distilled from a cited research pass (all URLs verified live). Durable state / liveness: Temporal [event-history](https://docs.temporal.io/encyclopedia/event-history) · [activity-execution](https://docs.temporal.io/activity-execution); [K8s probes](https://kubernetes.io/docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes/) · [K8s Leases](https://kubernetes.io/docs/concepts/architecture/leases/); [Erlang/OTP supervision](https://www.erlang.org/doc/system/sup_princ.html); [AWS Step Functions](https://docs.aws.amazon.com/step-functions/latest/dg/welcome.html); [LangGraph checkpointers](https://docs.langchain.com/oss/python/langgraph/checkpointers). Resilience: [AWS backoff+jitter](https://aws.amazon.com/blogs/architecture/exponential-backoff-and-jitter/) · [Google SRE cascading failures](https://sre.google/sre-book/addressing-cascading-failures/) · [Azure Retry](https://learn.microsoft.com/en-us/azure/architecture/patterns/retry) · [Azure Circuit Breaker](https://learn.microsoft.com/en-us/azure/architecture/patterns/circuit-breaker) · [Claude API errors](https://platform.claude.com/docs/en/api/errors) · [Stripe idempotency](https://docs.stripe.com/api/idempotent_requests). Verification: [SWE-bench](https://arxiv.org/abs/2310.06770) · [MT-Bench / LLM-as-judge](https://arxiv.org/abs/2306.05685) · [CriticGPT](https://arxiv.org/abs/2407.00215) · [self-consistency](https://arxiv.org/abs/2203.11171) · [multi-agent debate](https://arxiv.org/abs/2305.14325) · [Self-Refine](https://arxiv.org/abs/2303.17651) · [Spec Kit](https://github.com/github/spec-kit). Stall/loop: [Reflexion](https://arxiv.org/abs/2303.11366) · [ReAct](https://arxiv.org/abs/2210.03629) · [Tree of Thoughts](https://arxiv.org/abs/2305.10601) · [CrewAI](https://docs.crewai.com/concepts/agents) · [AutoGen termination](https://microsoft.github.io/autogen/stable/user-guide/agentchat-user-guide/tutorial/termination.html). Context: [lost-in-the-middle](https://arxiv.org/abs/2307.03172) · [MemGPT](https://arxiv.org/abs/2310.08560) · [Anthropic context engineering](https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents) · [Anthropic multi-agent system](https://www.anthropic.com/engineering/built-multi-agent-research-system).

> **Pending:** a Claude-Code-specific mechanics pass (agent-team registry behavior on outage, exact hook events, compaction/resume specifics) is running in parallel; its findings will be folded into §3.A/B/D and the open decisions.
