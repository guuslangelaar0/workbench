#!/usr/bin/env bash
# CADENCE CONVENIENCE — one entry point for "is the way of working still good?".
# Runs the FREE checks always (the structural expectancy gate + the offline conformance
# harness), and the PAID live checks only when WB_BENCH=1. Prints a consolidated summary
# so a workbench release / a descriptions edit has a single command to gate on.
#
# Usage: bench.sh            free checks (structural gate + conformance --simulate)
#        WB_BENCH=1 bench.sh free checks + LIVE conformance (drives the real model; costs tokens)
#        bench.sh --set train|holdout|all   restrict the conformance set (default all)
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SET="all"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --set) SET="$2"; shift 2 ;;
    *) echo "bench.sh: unknown arg '$1'" >&2; exit 64 ;;
  esac
done

rc=0
echo "═══ workbench bench — cadence check ═══"

echo; echo "1) expectancy gate (structural, free)"
bash "$SELF_DIR/expectancy-gate.sh" || rc=1

echo; echo "2) conformance harness (offline --simulate, free)"
bash "$SELF_DIR/bench-intents.sh" --simulate --set "$SET" | tail -2 || rc=1

if [ "${WB_BENCH:-0}" = 1 ]; then
  echo; echo "3) conformance LIVE (drives the real model — costs tokens)"
  WB_BENCH=1 bash "$SELF_DIR/bench-intents.sh" --set "$SET" | tail -3 || rc=1
else
  echo; echo "3) conformance LIVE — skipped (set WB_BENCH=1 to run; it costs API tokens)"
fi

echo; echo "═══════════════════════════════════════"
[ "$rc" = 0 ] && echo "bench: OK" || echo "bench: FAILED (a check above did not pass)"
exit "$rc"
