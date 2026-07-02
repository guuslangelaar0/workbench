#!/usr/bin/env bash
# Correct behavior: with #1203 AND #1204 both already covered (post-variant.sh), the
# new retro entry must target #1207 — the oldest verified/shipped admin task without
# one. Confirms the mechanism generalizes past a single hardcoded ID.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../lib.sh"

count_1203="$(el_ledger_count_retro_entries_for .claude/admin-evolution/ideas-log.md 1203)"
[ "$count_1203" -eq 1 ] || { echo "expected #1203 to stay at exactly 1 retro entry (already covered); found $count_1203" >&2; exit 1; }
count_1204="$(el_ledger_count_retro_entries_for .claude/admin-evolution/ideas-log.md 1204)"
[ "$count_1204" -eq 1 ] || { echo "expected #1204 to stay at exactly 1 retro entry (already covered); found $count_1204" >&2; exit 1; }

el_ledger_has_retro_entry_for .claude/admin-evolution/ideas-log.md 1207 || {
  echo "no new retrospective audit entry for #1207 (the actual oldest unaudited task after the variant)" >&2
  exit 1
}
exit 0
