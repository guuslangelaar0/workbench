# Evolution-loop conformance eval — case format + assumptions

Same shape as `test/benchmark/intents/` (a natural-language prompt + an effect-based
oracle reading real project-FS ground truth), applied to the evolution-loop "summit"
mechanism described in `docs/superpowers/specs/2026-07-02-admin-evolution-loop-design.md`
(written against a beebeeb.io-specific admin track; this suite tests the **generalized,
project-configurable mechanism** a teammate is building in `feat/evolution-loop`).

Run via `scripts/bench-evolution-loop.sh` (see that script's header for full usage). Quick
reference:

```sh
bash scripts/bench-evolution-loop.sh --simulate          # free, offline, always-on
WB_BENCH=1 bash scripts/bench-evolution-loop.sh           # live, drives claude -p, costs tokens
bash scripts/bench-evolution-loop.sh --simulate --only 02-critic-rejects-duplicate
bash scripts/bench-evolution-loop.sh --simulate --keep   # keep scratch project dirs for debugging
```

Two complementary lightweight cases also live in `test/benchmark/intents/cases/15-*` and
`16-*` (tagged `holdout`, per this project's own anti-overfit convention) — those test
whether the natural-language TRIGGER PHRASE alone routes to the summit at all, the same
kind of check the other 14 intent cases make for ordinary routing. The cases here are the
DEEP layer: given the summit already ran, is the OUTPUT actually good.

## Fixture

`test/benchmark/evolution-loop/fixture/project-a/` is a synthetic project pre-populated
with:
- `.claude/tasks/{backlog,in-development,verified,shipped,decisions}/` — known task
  content, including a duplicate-bait backlog task (#1200), a rejected-decision (#1205),
  and two retrospective-audit candidates: #1204 (already audited, must NOT be re-audited)
  and #1203 (not yet audited, is the correct pick).
- `.claude/admin-evolution/ideas-log.md` — a ledger with two prior summits' worth of
  history, seeded so dedup/coverage checks have real precedent to grep against.
- `.workbench/config.json` — see the `_ASSUMED_evolution_loop` ASSUMPTION note below.
- `.claude/admin-evolution/NOW-for-eval-fixture-only` — a fixture-only "current time"
  marker (`2026-07-02T09:00:00Z`) so elapsed-time cases have an unambiguous reference
  point instead of relying on wall-clock guessing.

Each case copies this fixture fresh, optionally runs a `variant.sh` to mutate it for that
specific scenario (e.g. raise/lower backlog count, age `last_summit_at`), then either
fakes the correct behavior (`--simulate`, offline, free) or drives the real model
(`WB_BENCH=1`, live, costs tokens), then scores the result against `oracle.sh`.

## Case index

| id | design-spec question | what it proves |
|----|----|----|
| `01-synthesis-well-formed` | Q1 | synthesis produces a REAL task (placeholders replaced, not just the skeleton), tagged the right Track, with a ledger entry |
| `02-critic-rejects-duplicate` | Q2 | a planted idea that duplicates an EXISTING BACKLOG task is rejected, not re-queued |
| `03-critic-rejects-decided-against` | Q2 | a planted idea matching something already in `decisions/` is rejected citing that decision |
| `04-critic-rejects-vague` | Q2 | a planted vague/unscoped idea is rejected for lacking checkable acceptance criteria, WHILE a concrete companion idea from the same summit still gets synthesized (proves real judgment, not "reject everything") |
| `05-retro-skips-already-audited` | Q3 | the retrospective mandate does not re-audit a task with an existing `retrospective audit of task #NNNN` ledger entry, and picks the oldest task without one |
| `06-retro-picks-unaudited` | Q3 | after BOTH pre-existing candidates get covered (via `variant.sh`), a THIRD, newer task is correctly picked up — proves the mechanism greps the ledger generically rather than having any task ID hardcoded |
| `07-trigger-fires-low-backlog` | Q4 | backlog-below-threshold alone fires the trigger even when the elapsed-time leg is false |
| `08-trigger-fires-24h-elapsed` | Q4 | elapsed-time-over-24h alone fires the trigger even when backlog is fully stocked (the spec's explicit "so quiet periods don't starve the retrospective mandate" case) |
| `09-trigger-does-not-fire` | Q4 | when NEITHER leg is true, no summit runs at all — ledger and backlog are byte-for-byte unchanged, and the run output explicitly names why |

Every oracle in this suite was verified against a deliberately-broken "bad" simulate run
(a rubber-stamping critic, a re-audited task, a trigger that fires when it shouldn't) to
confirm it actually fails in that case and isn't a rubber stamp itself. See the session
notes / eval-authoring report for the specific bad-run transcripts; the important property
is that every `oracle.sh` here has been exercised both ways, not just against its own
matching `simulate.sh`.

## ASSUMPTIONS — read before trusting a failure

The design spec (2026-07-02-admin-evolution-loop-design.md) is stable on the MECHANISM
shape (5 personas, dual mandate, ideas ledger, synthesis into the existing task format,
two-leg OR trigger) but says nothing about file paths, config schema, or command/skill
names — because the generalized implementation didn't exist yet when this suite was
written (per instructions, built test-first against the spec's CONTRACT). Concretely:

1. **`.workbench/config.json` has no `_ASSUMED_evolution_loop` key upstream.** The current
   `templates/schemas/config.schema.json` (checked as of this suite's authoring) has no
   persona-roster or trigger-threshold fields at all. The block used here (`track`,
   `summit_trigger.{backlog_below,max_hours_since_last_summit}`, `personas.{generators,
   critic}`, `ideas_ledger_path`, `last_summit_at`) is this suite's own invented shape,
   modeled on the existing `dial_overrides` convention. **If the landed implementation
   uses a different path or key names, update `EVOLUTION_CONFIG_PATH` in `cases/lib.sh`**
   and the `_ASSUMED_evolution_loop` block in the fixture + case `variant.sh`/`setup.sh`
   files that touch it (currently: fixture `.workbench/config.json`, and
   `08-trigger-fires-24h-elapsed/variant.sh`, `09-trigger-does-not-fire/variant.sh`).
2. **The ledger path `.claude/admin-evolution/ideas-log.md` is taken verbatim from the
   spec** (§"Ideas ledger") — this one should NOT need adjusting.
3. **"Workflow" in the spec is read as a description of the SHAPE of the mechanism**
   (a scheduled, non-interactive multi-`agent()`-call invocation), not a literal SDK
   class — this project's existing adversarial-verifier pattern (`skills/orchestration/
   SKILL.md`, `commands/verify.md`) already does "spawn several agents with an
   adversarial framing, require majority/critic verdict" via ordinary Task-tool agent
   dispatch, not a bespoke `Workflow()` primitive. The eval cases test OBSERVABLE
   EFFECTS (files, ledger entries, run-output text) so they don't actually care how the
   summit is implemented internally — this assumption only matters if you're trying to
   unit-test an internal `Workflow` call directly, which none of these cases do.
4. **No command/skill name is assumed.** The intent cases (`test/benchmark/intents/
   cases/15-*`, `16-*`) deliberately phrase prompts as natural-language observations
   ("backlog is thin", "go check what's already shipped") rather than naming a specific
   slash command, so they test the mechanism's OWN description/trigger regardless of
   what it ends up being called. If a specific command name lands (e.g.
   `/workbench:evolve`), consider ALSO adding a case that invokes it directly by name —
   that would be a stronger, more literal routing test than these two.
5. **The retrospective "oldest unaudited task" ordering is assumed to be by numeric task
   ID** (per the spec: "picks the oldest-by-task-ID verified/shipped admin tasks NOT yet
   present"). Cases `05`/`06` test this directly, including the multi-hop case (`06`)
   where the naive "first file alphabetically" heuristic and "lowest ID" heuristic
   happen to agree — if you want to stress-test that distinction further (e.g. a task ID
   that sorts differently alphabetically vs numerically, like `0099` vs `10001`), that's
   a gap this suite does not yet cover.
6. **Track filtering assumed to be `**Track:** admin`** (exact spec language: "Tasks land
   in `backlog/` exactly like any other task... with `**Track:** admin`"). This part is
   NOT an assumption — it's quoted directly from the spec — but note the fixture only
   ever tests the `admin` track; a project configuring the evolution loop for a
   DIFFERENT track name would need the fixture's `--track admin` calls updated to match.

## Known limitation of this suite (be honest about it)

None of these oracles can verify that a synthesized idea is GOOD in the sense of
"would Guus actually want this built" — same honesty caveat the project's own
`docs/benchmarking.md` states for the coding fixture (`true_win`/`FALSE_WIN` grading
proves correctness against a KNOWN oracle, not open-ended quality). What these oracles
CAN verify, mechanically:
- a task file is structurally well-formed and its placeholders were actually replaced
  (not "some file exists")
- a specific, deliberately-bad planted idea was rejected rather than rubber-stamped
- a specific ledger-dedup rule was followed rather than ignored
- a specific trigger condition fired/didn't fire under a specific synthetic state

That is a real, mechanical bar — considerably higher than "the routing fired" — but it
is still a proxy for "the critic persona is well-calibrated in general," which no
offline harness can fully verify. The genuinely open question (does the FOUR-persona
generation actually produce insightful ideas, as opposed to plausible-sounding ones) is
not machine-checkable at all with this project's current tooling; see the main report
for a discussion of that gap and how `--judge-model`-style LLM grading (used by the
gated, unavailable `claude plugin eval` subsystem) could eventually close it.
