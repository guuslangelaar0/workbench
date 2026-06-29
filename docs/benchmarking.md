# Benchmarking the way of working

Workbench measures itself. Every change to a description, a level preset, or a gate is
otherwise a vibe — this gives it a number. The headline question is: **do workbench's own
descriptions, triggers, and level presets make the model do the right thing?** A drop in
that number is a real, fixable finding (a description that stopped pulling its weight), not
noise.

There are two families of instrument: a free **offline** layer that runs every commit, and
a **live** layer that drives the real model and costs API tokens (run on cadence). The
design rationale is in [design/2026-06-29-self-benchmarking-expectancy-design.md](design/2026-06-29-self-benchmarking-expectancy-design.md).

## The one command

```sh
scripts/bench.sh                # free: structural gate + offline conformance
WB_BENCH=1 scripts/bench.sh     # + LIVE conformance (drives the real model; costs tokens)
scripts/bench.sh --set holdout  # restrict the conformance set (train|holdout|all)
```

That's the cadence check. Everything below is what it composes.

## Layer 1 — offline (free, every commit)

### `/workbench:score` — the expectancy scorecard
Each task is a "trade"; the loop's quality and economics fold into one **expectancy** figure
(per task and per 100k tokens) plus a 0–100 grade and a trend. A *gamed* or *regressed*
close **lowers** it — it scores reality, not the loop's claims. Reads the append-only
`.workbench/metrics.tsv` + the token ledger. This is a **process** proxy: it knows a task
was accepted clean, not whether the feature is genuinely good.

### `scripts/expectancy-gate.sh` — the regression gate for the way of working
Asserts the invariants the live conformance depends on: the intent-routing table in the
scaffolded CLAUDE.md, routing keywords in the `mc`/`suggest` descriptions, a description on
every command and skill, and the conformance harness still scoring a clean N/N in
`--simulate`. A change that would make the loop behave worse fails the gate. Its `--live`
tier compares the real conformance score against `test/benchmark/baseline`.

## Layer 2 — live (costs tokens, run on cadence)

### Intent→behavior conformance — the primary benchmark
`scripts/bench-intents.sh` runs each case in `test/benchmark/intents/cases/` — a
natural-language intent + a level + an **effect-based oracle** ("did the correct behavior
happen?"). It drives the real model (`claude -p --plugin-dir`) and reads the project FS +
captured output. It does **not** test the model's coding skill; it tests whether the
plugin's descriptions make the model route correctly.

```sh
bash scripts/bench-intents.sh --simulate          # free offline harness check
WB_BENCH=1 bash scripts/bench-intents.sh           # live (costs tokens)
WB_BENCH=1 bash scripts/bench-intents.sh --set train
```

Cases are tagged `train` or `holdout` (a `set` file, default `train`). The split exists so
the knob search can optimize on **train** and validate on the reserved **holdout** without
overfitting the metric.

### Live oracle benchmark (coding) — the secondary sanity layer
`test/benchmark/run.sh` + `scripts/bench-score.sh` drive the loop against a coding fixture
with hidden oracles and score outcomes against **ground truth, not self-report**:
`true_win` / `FALSE_WIN` (overclaimed) / `unclaimed_win` / `honest_miss`. This is where
overclaiming and regressions get caught — the scorecard can't see them. Gated by `WB_BENCH=1`;
`--simulate [honest|sloppy]` exercises the harness offline.

## The optimizer — `scripts/knob-search.sh` (BM-6)

Once there's a number, improving workbench is a loop: change a knob → re-measure → keep iff
the number went up. A **knob** is anything that shapes how the model reads the plugin (a
description, the routing table, a dial preset). A **candidate** is an overlay tree under
`test/benchmark/knobs/candidates/<name>/overlay/`. The search scores baseline + every
candidate on **train**, ranks them, and proposes the strict winner — **recommend-only**: it
prints the apply command, it never mutates the plugin. A train winner is validated on
**holdout**; one that wins on train but drops on holdout is rejected as overfit.

```sh
bash scripts/knob-search.sh --simulate    # free plumbing check
WB_BENCH=1 bash scripts/knob-search.sh     # real search (costs tokens)
```

See [`test/benchmark/knobs/README.md`](../test/benchmark/knobs/README.md) for the candidate format.

## Suggested cadence

| When | Run | Cost |
|------|-----|------|
| Every commit (CI) | `scripts/expectancy-gate.sh` + `bench-intents.sh --simulate` (both via `scripts/bench.sh`) | free |
| Before a workbench release, or after editing any description / CLAUDE.md template / level preset | `WB_BENCH=1 scripts/bench.sh` | tokens |
| When hunting a better description | `WB_BENCH=1 scripts/knob-search.sh` | tokens |
| Per real project, anytime | `/workbench:score` | free |

After a live run you trust, record the number in `test/benchmark/baseline` so the gate's
`--live` tier can catch a future regression.

## Honesty caveats

- **Self-measurement is gameable** — mitigated by counting only gate-survived closes as wins.
- **Proxy ≠ quality** — the scorecard measures process; only the live oracles measure correctness.
- **Variance** — live runs vary; treat a single number as a sample, re-run before trusting a move.
- **Goodhart** — optimizing against the metric erodes it; the train/holdout split and a growing
  oracle set are the defense. Keep adding cases.
