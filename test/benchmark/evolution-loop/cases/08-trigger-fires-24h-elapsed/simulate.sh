#!/usr/bin/env bash
# Genuinely exercises the real trigger: `evolve.sh check` is run for real against the
# variant's real state (backlog filled to 5 unblocked admin tasks, last-summit aged to
# 10 real days ago) and its actual first line is captured to .evolve-check-output —
# the oracle asserts on THAT real captured output, not keywords in a hand-written
# report. Only if the real command says "due ..." does the retrospective-heavy summit
# actually proceed, and the retro target itself comes from the real
# `evolve.sh retro-candidates`, not a hardcoded id.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../lib.sh"

bash "$ROOT/scripts/evolve.sh" check --target . > .evolve-check-output 2>&1
check_line1="$(head -1 .evolve-check-output)"

case "$check_line1" in
  due*)
    bash "$ROOT/scripts/evolve.sh" record-summit --target . >/dev/null
    target_id="$(bash "$ROOT/scripts/evolve.sh" retro-candidates --target . --track admin --limit 1)"
    bash "$ROOT/scripts/evolve.sh" log --target . \
      --persona critic \
      --idea "retrospective audit of task #$target_id" \
      --disposition "verified but checkbox-done — no search/filter/export — queued follow-up. (trigger: 24h+ elapsed since last summit, backlog was already full)"
    echo "workbench: evolve.sh check reported '$check_line1' -> backlog was full, but elapsed time since last summit exceeded the cadence ceiling, summit triggered (retrospective audited #$target_id)" > .run-output
    ;;
  *)
    echo "workbench: evolve.sh check reported '$check_line1' -> no summit run" > .run-output
    ;;
esac
