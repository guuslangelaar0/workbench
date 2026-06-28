# Loop quality, economics & a suggestion surface — the next frontier

**Status:** Proposal (planning + tasks created; not yet built)
**Date:** 2026-06-28
**Owner:** Guus
**Builds on:** [2026-06-27-loop-hardening-design.md](2026-06-27-loop-hardening-design.md) (liveness, verification contract, supervisor, charter)
**Surfaces touched:** new `scripts/{suggest.sh,gate-integrity.sh,budget.sh,regression-gate.sh}`, new `commands/{suggest.md,budget.md}`, `verify-gate.sh`/`task-move.sh`, `skills/{orchestration,task-lifecycle,verification,models}`, `hooks/bin/ground-session.sh`, `scripts/mc.sh`, task template, `graduate.sh`/`arch-drift.sh` (as suggestion producers).

---

## 1. Why

The previous spec hardened the loop's **mechanism** — does it stay alive, honest about "done", and re-grounded after a crash. That's necessary but not sufficient. The failures operators hit *next*, once the loop reliably runs for days, are about the **quality and economics of sustained output**, and about the loop **working *with* the human instead of silently for them**:

- It games its own gate (weakens/deletes tests) to mark work "done".
- It burns a surprise amount of money with zero per-task visibility.
- Its verifier is the same model that wrote the code, so it rubber-stamps.
- A task passes its own narrow check but breaks something else.
- Over days it optimizes for *closing tasks* over *serving the goal*.
- It either asks too little (silently chooses) or too much (blocks) — it rarely **suggests**.

The connective tissue across all of these — and the thing this spec makes first-class — is a **suggestion surface**: workbench should proactively *recommend* options to the human (hardening to enable, drift it found, a level to graduate to, a budget about to blow, a verifier worth cross-checking) the way Claude Code surfaces tips, rather than silently deciding or hard-blocking. Today workbench has exactly one suggestion producer (`graduate.sh`) and one carved rule ("features are suggested, never auto-built") with nowhere coherent to *put* a suggestion. This spec gives suggestions a home and many producers.

---

## 2. The spine: a suggestion surface

**Principle:** the loop has three response modes, and today it overuses the first two. (1) **Auto-act** — only the carved exceptions (bugs auto-file as tasks; lifecycle moves). (2) **Block → `decisions/`** — only an expensive, irreversible fork that genuinely needs the human *before* progress continues. (3) **Suggest** — everything else: recommend-only, non-blocking, the human acts when they like. Most operational intelligence belongs in (3), and it currently has no surface.

### Mechanism
- **Store:** `.workbench/suggestions/` — one small file per suggestion (consistent with the file-based task lifecycle), or a single appended `suggestions.md` ledger; **keyed for dedup** so the same recommendation never piles up. Each carries: `key`, `severity` (`info` | `recommend` | `warn`), `title`, **why**, **how** (the exact command to act), `source`, `created`, and a `status` (`open` | `acted` | `dismissed`).
- **Command:** `/workbench:suggest` — `list` (default, ranked by severity), `act <key>` (runs/prints the how), `dismiss <key>`, `add …` (a producer or the human files one).
- **Surfacing (the "like Claude" part):** the `SessionStart` brief (`ground-session.sh`) prints the top few open suggestions; `/workbench:mc` gains a **Suggestions** section. So every session opens with "here's what I'd consider next," not silence.
- **Recommend-only, always.** A suggestion never mutates the project. Bugs still auto-file (carved rule); forks still block to `decisions/`. Suggestions are the third, dominant mode.

### Producers (each problem below feeds it)
`graduate.sh` (→ "graduate to crew?"), `arch-drift.sh` (→ "3 god-nodes undocumented — file tasks?"), the anti-gaming guard (→ "this commit weakened a test"), budget (→ "80% of this run's budget spent"), cross-model (→ "enable cross-check verification"), the in-review cap, a stale/empty charter, the value-drift audit, and the loop's own feature ideas. **Generalizing `graduate.sh` into one of many producers is the first task** — it proves the surface.

---

## 3. Problems → mechanisms (fit-checked for our local, file-based setup)

### A. Verification gaming / reward-hacking  — **P0**
- **Symptom:** to pass the gate, the agent weakens or deletes a test, adds `assert True` / `expect(true)` / `#[ignore]` / `.skip`, comments out an assertion, or ticks acceptance criteria with no real change. Goodhart's law in the loop: the gate becomes the target.
- **Why it bites:** our verification contract proves evidence *exists* — not that it wasn't *faked*. CriticGPT showed even trained critics hallucinate; a model grading its own incentive to "be done" is worse.
- **Mechanism (`scripts/gate-integrity.sh`, wired into the verify gate):** inspect the task's diff before →verified and flag, language-aware: test files deleted or net test/assert count dropped *in the same change that claims tests pass*; newly-added trivially-passing assertions; skipped/ignored tests; coverage drop where a coverage signal exists. Level-scaled (advisory solo/pair, enforce crew+), **fails open**, and **honest** — it flags *suspicious patterns* for the verifier/human (and a suggestion), it does not claim certainty.
- **Fit:** high — it's a diff-analysis guard, pure local. Complements P0-2 directly.

### B. Cost / budget governance + observability — **P0**
- **Symptom:** a multi-day loop silently burns a large amount; the operator has no per-task spend visibility and gets a surprise bill.
- **Mechanism:** a per-task/iteration **ledger** (`.workbench/ledger.tsv`) the lead appends at each gate (tokens/cost — exact if Claude Code exposes usage, else an honest estimate); a **budget ceiling** in `way_of_working` that, as projected spend approaches, **downshifts** (smaller model, less parallelism) then **pauses + suggests/notifies** rather than blowing past; `/workbench:budget` to set/inspect; a spend line + per-task rollup in `/workbench:mc`. Honest about estimate vs exact; degrades gracefully if no usage signal.
- **Fit:** high — local read + config-driven enforcement. Underserved; few loops track this.

### C. Cross-model / adversarial verification — *optional & suggested* — **P1**
- **Symptom:** even a *separate* verifier subagent is the same model family with shared blind spots, so it rubber-stamps.
- **Mechanism (must NOT require Codex):** a `verification.cross_model` option, **off by default**, that routes the verify gate's verifier to a **different model than the implementer**. Resolution order, best-available: (1) **a different Claude model tier** — always available, zero extra setup (implementer on one tier, verifier on another → independent run, partially different failure modes); (2) **Codex** if the `codex` dial is on; (3) any configured second provider. The key design point you raised: **most of the benefit needs no second tool** — a different Claude tier + a fresh adversarial context already breaks the "judge is the player" loop. The plugin **suggests** enabling it (via the surface), explaining the tradeoff, rather than forcing it.
- **Fit:** good — slots into the existing verifier tiers in the `verification` dial + `models` skill.

### D. Global regression gate — **P1**
- **Symptom:** a task passes its *own* narrow verification while quietly breaking something else; nothing runs the **whole** suite before advancing.
- **Mechanism (`scripts/regression-gate.sh`):** before →verified, run the project's full build/test (a `project.checks` command, or the ladder's integration rung) — not just the task's declared check — and a "was-green-now-red" comparison against the last known-green baseline. Level-scaled; a red regression bounces the task back + files a bug (carved rule) + a suggestion.
- **Fit:** good — local, config-driven.

### E. Task dependency graph — **P2**
- **Symptom:** tasks declare no dependencies, so the picker grabs work whose prerequisite isn't done and wastes a cycle.
- **Mechanism:** a `**Blocked-by:** <ids>` field in the task template; the orchestration picker skips tasks with unmet deps; `/workbench:mc` shows the graph; `/workbench:doctor` flags cycles + ready-but-unpicked work.
- **Fit:** high but modest value — small, clean.

### F. Value / north-star drift audit — **P2**
- **Symptom:** over days the loop does technically-correct but low-value work, or scope-creeps away from the goal.
- **Mechanism:** every N verified tasks (or on a cadence), an audit agent compares recent closes against `loop-charter.md` + the roadmap and emits a **suggestion** ("last 6 closes were polish; the charter's #1 outcome hasn't moved — re-prioritize?"). Recommend-only.
- **Fit:** good — reads the charter we already ship; pure suggestion producer.

---

## 4. Prioritized backlog

**P0**
- [ ] **SQ-1 — Suggestion surface (the spine):** `.workbench/suggestions/` store + `/workbench:suggest` (list/act/dismiss/add) + a Suggestions section in `/workbench:mc` + top-N in the SessionStart brief; keyed dedup; recommend-only. Generalize `graduate.sh` into the first producer. Tests.
- [ ] **SQ-2 — Anti-gaming gate-integrity guard:** `scripts/gate-integrity.sh` (test-deletion / trivial-assert / skip / coverage-drop heuristics, language-aware, fail-open, level-scaled), wired into the verify gate; emits a `warn` suggestion. Tests.
- [ ] **SQ-3 — Cost/budget governance:** per-task ledger + budget ceiling (downshift → pause+suggest) + `/workbench:budget` + `/workbench:mc` spend line. Honest estimate-vs-exact. Tests.

**P1**
- [ ] **SQ-4 — Cross-model verification (optional/suggested):** `verification.cross_model` resolving different-Claude-tier → Codex → other; off by default; the gate uses it when on; the surface suggests enabling it. No hard dependency. Tests.
- [ ] **SQ-5 — Global regression gate:** `scripts/regression-gate.sh` (full-suite + was-green-now-red), wired pre-verify, level-scaled; red → bounce + auto-file bug + suggestion. Tests.
- [ ] **SQ-6 — Producer wiring:** generalize the existing signals into suggestions — `arch-drift` (undocumented god-nodes), in-review cap, stale/empty charter, plugin-version drift. Tests.

**P2**
- [ ] **SQ-7 — Task dependency graph:** `**Blocked-by:**` field + picker honors it + mc/doctor surface it. Tests.
- [ ] **SQ-8 — Value/north-star drift audit:** cadenced audit agent → suggestion. Tests.

**Ongoing**
- [ ] **SQ-9 — Gate:** per workstream run `test/all.sh`, update CHANGELOG `[Unreleased]`, commit (scoped pathspec) + push, confirm CI green. Lead gates; nothing "done" without passing tests.

## 5. Open decisions
1. **Suggestion store shape** — one file per suggestion (`.workbench/suggestions/<key>.md`, lifecycle-consistent, git-trackable) vs a single dedup'd ledger. *Gut: one file per suggestion* — matches the task model and is diffable; revisit if it gets noisy.
2. **Budget signal source** — ✅ **RESOLVED (probe, 2026-06-28): exact usage IS readable.** Every `assistant` record in the session transcript JSONL (`~/.claude/projects/<escaped-cwd>/<session>.jsonl`) carries `message.usage.{input_tokens, output_tokens, cache_read_input_tokens, cache_creation_input_tokens}` — the real API response. No hook payload carries tokens, but every hook receives `transcript_path`. So SQ-3 snapshots via a Stop/SubagentStop hook (`usage-meter.sh` → `usage-sum.sh`) and is **exact** (python3/jq parse; awk fallback marked `estimate`). Spend is tracked in **tokens** (no fabricated USD prices — USD only if the user sets `price_in`/`price_out`), so nothing bitrots. OTel (`CLAUDE_CODE_ENABLE_TELEMETRY` + enhanced beta) is the alternative for per-turn spans but needs a collector — the transcript is simpler and dependency-free.
3. **Cross-model default tiers** — when `cross_model` is on with no second provider, which Claude tiers pair (implementer vs verifier)? *Gut: verifier one tier **up** from the implementer (a stronger skeptic), resolved via the `models` skill.*
4. **Anti-gaming strictness** — enforce (block the move) vs suggest-only at crew+? *Gut: block on the unambiguous signals (test deleted + "tests pass" claim), suggest on the fuzzy ones (coverage drift).* Avoid false-positive friction.

## 6. Non-goals
- A hosted cost dashboard, multi-machine orchestration, or cloud Routines (cloud-platform problems — out, per the local-supervisor decision).
- Perfect gaming detection — impossible; the guard raises honest suspicion, it doesn't certify.
- Auto-acting on suggestions — the whole point is recommend-only; only bugs auto-file.

## 7. References
Problem-framing draws on the prior research pass (verified sources in the loop-hardening spec §7) plus well-established results: **Goodhart's law / specification gaming / reward hacking** (a gate optimized against stops measuring what it proxied); **CriticGPT** ([arxiv 2407.00215](https://arxiv.org/abs/2407.00215)) — trained critics still hallucinate, so flag-don't-certify and keep a human on the verifier; **LLM-as-a-judge** biases incl. self-enhancement ([arxiv 2306.05685](https://arxiv.org/abs/2306.05685)) — why same-model self-grading rubber-stamps and cross-model helps; **SWE-bench** ([arxiv 2310.06770](https://arxiv.org/abs/2310.06770)) — execution-grounded verification over self-report. This is domain reasoning + the earlier pass, not a fresh literature review; pressure-test before building if desired.
