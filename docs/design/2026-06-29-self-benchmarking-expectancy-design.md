# Self-benchmarking — giving the loop an expectancy number

**Status:** Implemented 2026-06-29 — BM-1..BM-8 (all). The intent-conformance benchmark (BM-8) is the primary one; BM-6 (knob search) turns it into an optimizer. Conformance fixture widened to 11 cases with a train/holdout split (anti-overfit). 50 test suites green. Live conformance history: 2/5 → 5/5 (first description fix) → on the widened set the full live run scored **9/11**, and **both failures were held-out cases** (the Goodhart guard catching what the train-tuned descriptions didn't generalize): `in-review cap not checked before pulling new work`, and `a "plan a big multi-part effort" intent at solo not landing as tracked backlog tasks`. Two routing-table rows fixed both; re-validated live → **11/11**. (Note: those two holdout cases are now "seen" — replenish the holdout with fresh unseen cases before trusting it as an anti-overfit guard again; see §6c.)
**Date:** 2026-06-29
**Owner:** Guus
**Builds on:** the loop-hardening + loop-quality-economics instruments (verify-gate, gate-integrity, budget/ledger, regression-gate, lane attempts, value-audit) — they already emit the raw signal; this turns it into a score.

---

## 1. Why

workbench now *measures* many things but answers no single question: **is the way of working good, and did a change to it make the loop better or worse?** Without a number, every tweak to a skill, a dial, or a gate is a vibe. We want a metric we can (a) compute automatically, (b) trust, and (c) optimize against — so improving workbench becomes a measurable loop instead of a guess.

## 2. What "expectancy" means here

Borrowed from trading. **Each task is a trade.** It either wins (a clean verified/shipped close that delivered value) or loses (bounced for rework, caught gaming, introduced a regression, or just burned tokens going nowhere). The classic formula:

```
Expectancy = (Win% × AvgWin) − (Loss% × AvgLoss)
```

mapped to the loop:

- **Win** = a task reached `verified`/`shipped` *with evidence* AND survived the anti-gaming and regression gates. `AvgWin` = average value of a clean close (optionally weighted by the task's `**Estimate:**`/impact).
- **Loss** = a task was bounced, abandoned, gamed, or caused a regression. `AvgLoss` = the wasted cost (tokens + a penalty).

The headline number is **expectancy per 100k tokens** — expected net verified-value per unit of spend. That folds quality *and* economics into one figure: a loop that ships more, rubber-stamps less, regresses less, and burns fewer tokens scores higher. Map it to a 0–100 "loop health" band for at-a-glance, keep the raw expectancy for trend lines.

**Crucial honesty rule:** a *gamed* win must **lower** expectancy, not raise it. The score counts a close as a win only if it survived `gate-integrity` + `regression-gate`; a flagged-then-advanced task is a loss. Otherwise we'd be scoring the loop's *claims*, not reality — the exact trap workbench exists to avoid.

## 3. Two layers (cheap proxy → honest oracle)

### L1 — Offline scorecard (free, always-on)
The instruments emit *current state*; scoring needs *history*. So add one append-only **metrics event log** (`.workbench/metrics.tsv`) that the existing gates/hooks write a line to at each decision: `task_closed`, `task_bounced`, `gaming_flag`, `regression_red`, `restart`, `drift_due`, plus token deltas (already in `ledger.tsv`). Then `scripts/score.sh` / `/workbench:score` aggregates it into the component metrics + the expectancy number + a grade + a trend vs the last score. **Zero API cost**, runs anytime, scores the *real* project.
- Measures **process health** — rework rate, gaming caught, regressions, cost/close, drift episodes, restart-intensity.
- It's a **proxy**: it knows a task was *accepted clean*, not whether the feature is genuinely *good*. Honest about that.

### L2 — Live golden-task benchmark (costs tokens, run on cadence)
A seeded **benchmark project** with N tasks that have **machine-checkable oracles** (a known-correct test that must pass, a file that must exist, an output that must match). Run the *real plugin* headless against it — extending the existing `test/e2e/run.sh` harness (`claude -p --plugin-dir`) — let the loop work the tasks, then **score outcomes against the oracles**. This is execution-grounded (SWE-bench-style), so the win/loss labels are ground truth, not self-report → the **honest expectancy**.
- Stochastic: one run is noisy. Run K seeds, report **mean ± spread**, not a point.
- Costs API tokens per run → cadence/CI, not every commit.

## 4. The optimization meta-loop

Once there's a number, optimizing workbench is itself a loop: **change one knob → re-benchmark → keep iff expectancy ↑.** Knobs: a dial preset, a gate threshold, a prompt in a skill, a model tier, the cross-model setting. The number becomes a **regression gate for the way of working itself** — every PR to workbench runs L1 on a recorded run (free) and L2 on cadence (paid); a drop in expectancy blocks the change. Later this can be automated (grid/random search over dial configs), but the first win is just *having the gate*.

## 5. Honesty caveats (read before trusting a number)
1. **Self-measurement is gameable** — mitigated by counting only gate-survived closes as wins (§2).
2. **Proxy ≠ quality** — L1 measures process; only L2's oracle measures correctness. Don't quote L1 as "the loop is good," quote it as "the process is healthy."
3. **Variance** — LLM runs vary; a single L2 number is noise. Always K-seed and report spread.
4. **Goodhart** — once we optimize against expectancy, it stops being a neutral measure. Keep the oracle set growing and partly held-out so we can't overfit the metric.

## 6. Backlog
**P0**
- [x] **BM-1 — Metrics event log:** append-only `.workbench/metrics.tsv`; the existing gates/hooks emit `task_closed|task_bounced|gaming_flag|regression_red|restart|drift_due` + token deltas. Tests.
- [x] **BM-2 — `/workbench:score` (offline scorecard):** `scripts/score.sh` aggregates the log + ledger into components + expectancy/100k + grade + trend. Tests.

**P1**
- [x] **BM-3 — Golden benchmark project:** a seeded fixture (N tasks + machine-checkable oracles, mixed difficulty).
- [x] **BM-4 — Live benchmark runner:** extend `test/e2e/run.sh` to run the plugin against the fixture, score vs oracles, K seeds, mean±spread → an expectancy report.

**P2**
- [x] **BM-5 — Expectancy gate for workbench's own CI:** block a workbench change that drops L1 expectancy; run L2 on cadence.
- [x] **BM-6 — Knob search:** `scripts/knob-search.sh` sweeps candidate overlay dirs (alternative descriptions / CLAUDE.md routing / dial presets) against the conformance **train** set, ranks them, and proposes the strict winner (recommend-only — prints the apply command, never mutates the plugin). A train winner is validated on the reserved **holdout** set; one that wins on train but drops on holdout is rejected as overfit (§5.4). Ties keep the baseline. Offline-tested via stubbed per-candidate scores; live gated by `WB_BENCH=1`.

**Follow-up**
- [ ] **CB-6 — Replenish the holdout.** Cases `09` and `11` were fixed against (§6c), so they're tuned-against now. Author 2–3 new, genuinely-unseen holdout cases (and/or rotate the tags) and live-validate, so the held-out set is a clean anti-overfit signal again before BM-6 is run for real.

## 6b. The benchmark's true target — description conformance, not model skill (added 2026-06-29)

A correction after the first live runs pinned at 100/100: a coding-difficulty fixture (BM-7) just measures *the model*. A strong model (the one users should run — **always Opus**) aces it honestly, so the number can't discriminate between workbench configs. That's the wrong thing to measure.

**What we actually test: do workbench's own descriptions, triggers, and level presets make Opus do the right thing?** A user expresses an intent; the right command/skill should fire, the way of working should show up, and at a given level the right behavior should be enforced. The oracle is **"did the correct behavior happen,"** not "is the code correct." When the number drops, it means a *description* (a command's `description`, a skill's trigger, a way-of-working rule) isn't pulling its weight for Opus — which is exactly the thing we can fix and want a regression gate on.

**BM-8 — intent→behavior conformance benchmark.** Each case = a natural-language intent + a level + an effect-based oracle, e.g.:
- "I found a bug: …" → a task is **auto-filed** (the "bugs auto-file" rule).
- "Idea for later: …" → a **suggestion** is filed, not an auto-built feature (the "features suggest" rule).
- "Where does the project stand?" → **/workbench:mc** fires (status-intent routing).
- "Start work on X" → a task is created.
- (crew) "verify task 0001" with no evidence → the **verify gate holds** (refuses), proving the gate's description survives pressure.

Run live with `claude -p --plugin-dir` (always the user's real model); oracles read the project FS + the captured output. A `--simulate` path fakes the correct behavior via the plugin's own scripts so the harness is CI-testable without tokens. Conformance < 100 is a real finding: a description that doesn't make Opus do the right thing. This is the primary benchmark; the BM-7 coding fixture stays as a secondary no-gaming/no-regression sanity layer.

## 6c. The first held-out catch (2026-06-29) — and the holdout-rotation rule

The widened set's first full live run scored **9/11**. The eight **train** cases all passed; the two failures were both **holdout** cases — exactly the generalization the train-tuned descriptions missed:
1. **`09-inreview-cap`** — at the in-review cap, "grab the next feature and start building it" had the model open new work instead of recognizing the cap and draining it. The cap rule lived only in the loop-cadence step, not tied to the *pull-new-work* intent.
2. **`11-flat-solo`** — "plan a big multi-part effort" at solo produced a prose plan, not tracked backlog tasks. There was no routing rule for *decomposition* (the fleet counterpart `10-epic-fleet` passed because epics are explicit).

Both were fixed with two **intent-routing rows** in the scaffolded `CLAUDE.md` (a cap-check-before-pull row, and a level-aware decomposition row: epic at fleet, flat backlog tasks at lighter levels). Re-validated live → both PASS (11/11). These are genuine behavior fixes, not keyword-gaming — the oracle keywords appear because the corrected behavior naturally produces them.

**Holdout-rotation rule (the integrity cost).** Fixing against a held-out case "spends" it: 09 and 11 are now tuned-against and no longer a clean anti-overfit signal. The held-out set guards the **automated** knob search (BM-6), which only ever sees train — so it remains valid for that. But before quoting the holdout as a fresh generalization check again, **replenish it with new, genuinely-unseen cases** (or rotate which cases are held out). A holdout you've optimized against is just more train data.

## 7. Non-goals
- A perfect correctness oracle for arbitrary real projects (impossible — that's why L1 is a proxy and L2 uses *seeded* tasks).
- Optimizing the number at the expense of the thing it proxies (see §5.4).
