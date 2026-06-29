---
description: Show the loop's expectancy — expected net verified-value per task and per 100k tokens, scored from the metrics log
allowed-tools: ["Bash", "Read"]
argument-hint: ""
---

You are the `/workbench:score` command. Show the project's loop expectancy.

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/score.sh" --target "${CLAUDE_PROJECT_DIR}"
```

It treats each task as a "trade" and computes, from the durable metrics log (`.workbench/metrics.tsv`) + the token ledger (`.workbench/ledger.tsv`):

- **wins** — clean closes (`verified`/`shipped` that survived the gates)
- **losses** — bounces (rework), gaming flags, regressions
- **friction** — restarts, drift episodes
- **EXPECTANCY / task** and **/ 100k tokens** — expected net verified-value (quality × economics in one number), with the trend vs the last score
- **GRADE** — 0–100, how much of the gross win value survived penalties

A *gamed* close lowers expectancy (the score reflects reality, not the loop's claims). Relay the scorecard, call out the trend direction, and if the grade is C or below name the biggest drag (the largest loss/friction bucket) and the suggestion that would address it. Weights are configurable in the config `score`{} object; defaults are sane. This is zero-cost — run it anytime, and after a batch of work to see whether the way of working is improving.
