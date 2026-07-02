#!/usr/bin/env bash
# Genuinely exercises the real retrospective-selection logic post-variant: `evolve.sh
# retro-candidates --track admin` does the actual ledger-grep-and-exclude against the
# variant's real .claude/tasks/{verified,shipped} state (which now includes #1207,
# added by variant.sh) — whichever id it picks is what gets audited and logged via the
# real `evolve.sh log` / `record-summit`. No hardcoded "#1207" anywhere in this script;
# the id comes from the real command, proving the mechanism generalizes rather than
# having any task ID hardcoded (the property this case exists to prove).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../lib.sh"

target_id="$(bash "$ROOT/scripts/evolve.sh" retro-candidates --target . --track admin --limit 1)"
[ -n "$target_id" ] || { echo "simulate.sh: evolve.sh retro-candidates returned nothing" >&2; exit 1; }

bash "$ROOT/scripts/evolve.sh" record-summit --target . >/dev/null

bash "$ROOT/scripts/evolve.sh" log --target . \
  --persona critic \
  --idea "retrospective audit of task #$target_id" \
  --disposition "verified, reason codes visible, but no filter/search by reason code across refunds — minor expansion queued"

echo "workbench: retrospective audited task #$target_id (oldest unaudited per evolve.sh retro-candidates, after #1203/#1204 covered)" > .run-output
