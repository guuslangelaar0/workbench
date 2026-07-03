#!/usr/bin/env bash
# correct behavior: "check what's already shipped for excellence" routes to the
# RETROSPECTIVE half specifically (not the generate-new-ideas half) — a new ledger
# entry naming "retrospective audit of task #0001" (the shipped task with no prior
# retro coverage) must appear, written with the structural [audit:#0001] marker
# (via `evolve.sh log --audit-of 0001`) so that coverage tracking actually counts it.
set -uo pipefail
grep -qiE 'retrospective|audit' "$RUN_OUTPUT" 2>/dev/null || exit 1
grep -iE 'retrospective audit of task #0001' .workbench/evolution/ideas-log.md 2>/dev/null | grep -q . || exit 1
# Also verify the structural [audit:#0001] marker was written (not just free text):
# _audited_ids / retro-candidates will only skip a task if the structural marker exists.
awk -F'\t' '$1 ~ /^\- \[[0-9]{4}-[0-9]{2}-[0-9]{2}\]$/ && $2 == "[audit:#0001]"' \
  .workbench/evolution/ideas-log.md 2>/dev/null | grep -q . || exit 1
exit 0
