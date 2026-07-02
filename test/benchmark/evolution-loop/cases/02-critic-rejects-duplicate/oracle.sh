#!/usr/bin/env bash
# Correct behavior: NO second task file for the same idea as #1200, AND the ledger
# records a rejection citing the duplicate. A critic that rubber-stamps everything
# would create a second "bulk cancel refunds"-shaped task in backlog/ — that must
# NOT happen (this is the primary "does the critic actually reject" oracle).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../lib.sh"

backlog_count() { ls .claude/tasks/backlog/*.md 2>/dev/null | wc -l | tr -d ' '; }
n="$(backlog_count)"
[ "$n" -eq 2 ] || { echo "expected backlog to stay at 2 files (no duplicate task created), got $n" >&2; exit 1; }

# no new file mentions bulk-cancel besides the pre-existing #1200
dupes="$(grep -rliE 'bulk.?cancel|bulk.?refund' .claude/tasks/backlog/ 2>/dev/null | grep -v '1200-' | wc -l | tr -d ' ')"
[ "$dupes" -eq 0 ] || { echo "a duplicate bulk-cancel task was created alongside #1200" >&2; exit 1; }

el_ledger_has_disposition_for .workbench/evolution/ideas-log.md 1200 'reject|duplicate' || {
  echo "ledger does not record a rejection citing #1200 / duplicate" >&2
  exit 1
}
exit 0
