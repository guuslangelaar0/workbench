---
description: Run workbench plugin-source self-test
allowed-tools: ["Bash", "Read", "Glob", "Grep"]
argument-hint: "[--skip-suite] [--live] [--live-coding]"
---

Run the workbench plugin-source self-test:

!`bash ${CLAUDE_PLUGIN_ROOT}/scripts/self-test.sh $ARGUMENTS`

Use `--live` before releases when the user asks whether workbench was actually live-tested: it runs the release gate with `WB_E2E=1` and `WB_BENCH=1`, and fails if either live layer skips. Summarize any failing check, the evidence path when present, and the exact next command to rerun after fixing it.
