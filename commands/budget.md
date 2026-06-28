---
description: Show or govern the loop's token spend — exact per-session/per-task usage, a token ceiling, and downshift-then-pause governance
allowed-tools: ["Bash", "Read"]
argument-hint: "[show|check|set ...|task <id> start|close]"
---

You are the `/workbench:budget` command. Read `$ARGUMENTS` and act on it.

Spend is tracked in **exact tokens**, read from the session transcript by the `usage-meter` hook (Stop/SubagentStop) — no fabricated USD prices, so nothing bitrots. A USD estimate appears only if you set per-MTok prices. All operations go through `scripts/budget.sh`.

If `${CLAUDE_PROJECT_DIR}/.workbench/config.json` doesn't exist, tell the user to run `/workbench` first and stop.

## `show` (default)

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/budget.sh" show --target "${CLAUDE_PROJECT_DIR}"
```

Prints cumulative session usage (input/output/cache + turns), the billable total, the ceiling and % used (if set), and a USD estimate (if prices are set). If it says "no usage snapshot yet", the meter hook hasn't recorded a turn — it will after the next turn ends.

## `check`

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/budget.sh" check --target "${CLAUDE_PROJECT_DIR}"
```

Compares spend to the ceiling. Exit `0` = ok/approaching, exit `3` = over. It files a `recommend` suggestion at the approach threshold (default 80%) and a `warn` suggestion when over — both via the suggestion surface. **The loop should run this between iterations**: on "approaching", downshift (smaller model / less parallelism); on "over", pause non-essential work and surface the suggestion to the human rather than blowing past the ceiling.

## `set`

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/budget.sh" set \
  --ceiling-tokens 5000000 --on-approach downshift --approach-pct 80 \
  --target "${CLAUDE_PROJECT_DIR}"
# optional USD estimate: --price-in <usd/MTok> --price-out <usd/MTok>
```

Writes a `budget{}` object into the config. `on_approach` ∈ `downshift|pause|notify`.

## `task <id> start|close`

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/budget.sh" task <id> start --target "${CLAUDE_PROJECT_DIR}"
bash "${CLAUDE_PLUGIN_ROOT}/scripts/budget.sh" task <id> close --target "${CLAUDE_PROJECT_DIR}"
```

Snapshots cumulative spend at task start and close and records the **delta** (this task's approximate cost) into `<cfg>/ledger.tsv`. The lead should call `start` when dispatching a task and `close` at its verify gate, so `/workbench:mc` can show per-task spend. (Approximate: it attributes all session tokens between the two snapshots to the task; concurrent lanes blur it.)
