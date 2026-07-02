#!/usr/bin/env bash
# correct behavior: "check what's already shipped for excellence" routes to the
# RETROSPECTIVE half specifically (not the generate-new-ideas half) — a new ledger
# entry naming "retrospective audit of task #0001" (the shipped task with no prior
# retro coverage) must appear.
set -uo pipefail
grep -qiE 'retrospective|audit' "$RUN_OUTPUT" 2>/dev/null || exit 1
grep -iE 'retrospective audit of task #0001' .workbench/evolution/ideas-log.md 2>/dev/null | grep -q . || exit 1
exit 0
