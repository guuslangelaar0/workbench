# Evolution-loop conformance eval — case format

Same shape as `test/benchmark/intents/` (a natural-language prompt + an effect-based
oracle reading real project-FS ground truth), applied to the evolution-loop "summit"
mechanism implemented in `scripts/evolve.sh` (deterministic plumbing: trigger, roster
validation, ledger, retrospective rotation) and the `evolution` skill / `/workbench:evolve`
command (the model-driven convening). The design origin was a beebeeb.io-specific admin
track; the landed mechanism is generalized and project-configurable — this suite tests
that generalized mechanism directly against its real implementation.

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
- `.workbench/evolution/personas.json` — the real roster file (schema:
  `templates/schemas/personas.schema.json`), a 4-generator + critic panel scoped
  `"track": "admin"`, modeled on the shipped `personas.admin-example.json` preset.
- `.workbench/evolution/ideas-log.md` — the real ledger (`evolve.sh log` / `record-summit`
  format), with two prior summits' worth of history seeded so dedup/coverage checks have
  real precedent to grep against.
- `.workbench/evolution/last-summit` — the real stamp file (`evolve.sh record-summit`
  writes it as epoch seconds), seeded 2 hours before the fixture's "now" so the base
  fixture's only due leg is backlog-low, not staleness.
- `.workbench/evolution/NOW-for-eval-fixture-only` — a fixture-only "current time" marker
  (`2026-07-02T09:00:00Z`) so elapsed-time cases have an unambiguous reference point
  instead of relying on wall-clock guessing.

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
confirm it actually fails in that case and isn't a rubber stamp itself — the important
property is that every `oracle.sh` here has been exercised both ways, not just against
its own matching `simulate.sh`. This suite was additionally checked against the REAL
`scripts/evolve.sh` directly (not just simulated): a scratch copy of the plugin had its
trigger's OR-condition and its retrospective ledger-audit tracking each independently
disabled, and `evolve.sh check` / `evolve.sh retro-candidates` run against this suite's
own fixture states confirmed the break flips the exact outcome each case depends on
(`due backlog-low` / `due summit-stale` → `not-due`; `1203` only → `1203, 1204` — i.e. a
re-suggested already-audited task). The scratch copy was discarded; `scripts/evolve.sh`
in this repo was never modified.

## Ground truth this suite is built against

This suite tests the LANDED implementation directly — no invented shapes remain.
Concretely, per `scripts/evolve.sh`, `templates/schemas/personas.schema.json`, and
`skills/evolution/SKILL.md`:

1. **Roster + trigger knobs live in `.workbench/evolution/personas.json`** — a dedicated
   file, NOT a block inside `.workbench/config.json`. Top-level scalar knobs are
   `cadence_hours` (default 24), `queue_low_water` (default 2), `retro_slice` (default 3),
   `track` (default all); `personas` is a flat array of `{name, role: "generator"|
   "critic", prompt}` objects — exactly one `critic`, at least one `generator`. This
   suite's fixture roster is `queue_low_water: 3` (to preserve the "keep 3 queued"
   framing the trigger cases were written against) and `track: "admin"`, modeled on the
   shipped `templates/evolution/personas.admin-example.json` preset.
2. **The ledger lives at `.workbench/evolution/ideas-log.md`**, a sibling of the roster —
   not under `.claude/admin-evolution/`. Entry format (written by `evolve.sh log`, one
   line, no wrapping): `- [YYYY-MM-DD] <persona> — <idea one-liner> — <disposition>`.
   `record-summit` heads each summit with `## Summit — <UTC date HH:MM>` (an em dash, not
   a bare date). Retrospective coverage is tracked by grepping the ledger for the literal
   phrase `retrospective audit of task #NNNN` — there is no separate tracking file.
3. **The "last summit ran at" stamp is `.workbench/evolution/last-summit`** — a plain
   epoch-seconds integer file written by `evolve.sh record-summit`, not an ISO string
   inside a config JSON. `evolve.sh check` computes `age_hours` from it directly.
4. **The trigger is `evolve.sh check`'s own OR condition**: due when unblocked backlog
   (via `deps.sh ready`, filtered to the roster's `track`) drops below `queue_low_water`,
   OR more than `cadence_hours` have elapsed since `last-summit`. Cases `07`–`09` exercise
   this directly against the real fixture states (verified independently of the offline
   `--simulate` harness — see the rigor-check paragraph above).
5. **Retrospective ordering is oldest-by-numeric-task-ID**, computed by `evolve.sh
   retro-candidates` scanning `.claude/tasks/{verified,shipped}/*.md` filenames and
   excluding whatever `evolve.sh audited` extracts from the ledger. Cases `05`/`06` test
   this directly; case `06`'s multi-hop scenario (both pre-existing candidates covered,
   a third newer task picked up) was independently confirmed against the real
   `retro-candidates` command (see rigor-check paragraph).
6. **Track filtering is `**Track:** admin`** on task files, matched via `evolve.sh
   check`/`retro-candidates --track` — the fixture only ever tests the `admin` track; a
   project configuring the evolution loop for a different track would need the
   `--track admin` calls throughout this suite updated to match.

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
