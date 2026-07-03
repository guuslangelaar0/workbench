#!/usr/bin/env bash
# Genuinely exercises the real retrospective-selection logic: `evolve.sh
# retro-candidates --track admin` does the actual ledger-grep-and-exclude (via
# `evolve.sh audited`) against the fixture's real .claude/tasks/{verified,shipped}
# state, and whichever id it picks is what gets audited and logged via the real
# `evolve.sh log` / `record-summit` — no hardcoded "#1203" anywhere in this script.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../lib.sh"

target_id="$(bash "$ROOT/scripts/evolve.sh" retro-candidates --target . --track admin --limit 1)"
[ -n "$target_id" ] || { echo "simulate.sh: evolve.sh retro-candidates returned nothing" >&2; exit 1; }

bash "$ROOT/scripts/evolve.sh" record-summit --target . >/dev/null

bash "$ROOT/scripts/task-new.sh" --target . --state backlog --track admin \
  --title "Expand invoice list view: search, filters, export" \
  --verification "Playwright screenshot" >/dev/null
new_file="$(ls .claude/tasks/backlog/*-expand-invoice-list-view-search-filters-export.md 2>/dev/null | head -1)"
new_id="$(basename "$new_file" | grep -oE '^[0-9]+')"

bash "$ROOT/scripts/evolve.sh" log --target . \
  --persona critic \
  --idea "retrospective audit of task #$target_id" \
  --disposition "verified but checkbox-done — no search, no date-range filter, no export, no link from a support ticket. Deserves to be bigger; queued follow-up as task #$new_id"

echo "workbench: retrospective audited task #$target_id (oldest unaudited per evolve.sh retro-candidates), queued follow-up #$new_id" > .run-output
