#!/usr/bin/env bash
# Correct behavior: no new backlog task resurrecting "shared login" (already rejected
# in decisions/#1205), and the ledger cites #1205 as the reason. A critic that doesn't
# actually cross-reference decisions/ would happily queue this as a new task.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../lib.sh"

new_tasks="$(grep -rliE 'shared.{0,15}(login|credential)' .claude/tasks/backlog/ .claude/tasks/in-development/ 2>/dev/null | wc -l | tr -d ' ')"
[ "$new_tasks" -eq 0 ] || { echo "a 'shared login' task was created despite standing decision #1205" >&2; exit 1; }

el_ledger_has_disposition_for .workbench/evolution/ideas-log.md 1205 'reject' || {
  echo "ledger does not record a rejection citing the standing decision #1205" >&2
  exit 1
}
exit 0
