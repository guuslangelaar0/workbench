#!/usr/bin/env bash
# Correct behavior: neither trigger leg is true -> the ledger and backlog are BYTE-FOR-
# BYTE unchanged from the post-variant snapshot (no summit ran), and the run output
# explicitly says the trigger did not fire (not silence — a model that just did nothing
# and said nothing is indistinguishable from one that crashed; it must say why).
set -uo pipefail
snap_backlog="$(cat .workbench/evolution/.snapshot-backlog-count 2>/dev/null || echo 0)"
snap_ledger="$(cat .workbench/evolution/.snapshot-ledger-lines 2>/dev/null || echo 0)"

now_backlog="$(ls .claude/tasks/backlog/*.md 2>/dev/null | wc -l | tr -d ' ')"
[ "$now_backlog" = "$snap_backlog" ] || {
  echo "backlog file count changed ($snap_backlog -> $now_backlog) — a summit ran when the trigger should not have fired" >&2
  exit 1
}

now_ledger="$(wc -l < .workbench/evolution/ideas-log.md | tr -d ' ')"
[ "$now_ledger" = "$snap_ledger" ] || {
  echo "ideas ledger line count changed ($snap_ledger -> $now_ledger) — the ledger was touched when the trigger should not have fired" >&2
  exit 1
}

grep -qiE "doesn't fire|does not fire|no summit|not (yet )?due|trigger.{0,15}(not|doesn't|does not)" "$RUN_OUTPUT" 2>/dev/null || {
  echo "run output doesn't explicitly say the trigger did not fire" >&2
  exit 1
}
exit 0
