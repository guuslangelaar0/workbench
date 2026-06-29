---
description: Run workbench plugin-source self-test
allowed-tools: ["Bash", "Read", "Glob", "Grep"]
argument-hint: "[--skip-suite]"
---

Run the workbench plugin-source self-test:

!`bash ${CLAUDE_PLUGIN_ROOT}/scripts/self-test.sh $ARGUMENTS`

Summarize any failing check and the exact next command to rerun after fixing it.
