#!/usr/bin/env bash
# Correct behavior: with #1203 AND #1204 both already covered (post-variant.sh), the
# new retro entry must target #1207 — the oldest verified/shipped admin task without
# one. Confirms the mechanism generalizes past a single hardcoded ID.
#
# Two levels of verification:
#  (a) the ledger shows a retrospective entry for #1207 (existing free-text grep via
#      el_ledger_has_retro_entry_for — proves the idea text is correct)
#  (b) `evolve.sh audited` now lists #1207 — proves the STRUCTURAL [audit:#1207]
#      marker was written (via --audit-of), not just free text that _audited_ids won't
#      count. A simulate.sh that omits --audit-of passes check (a) but fails check (b).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../lib.sh"

count_1203="$(el_ledger_count_retro_entries_for .workbench/evolution/ideas-log.md 1203)"
[ "$count_1203" -eq 1 ] || { echo "expected #1203 to stay at exactly 1 retro entry (already covered); found $count_1203" >&2; exit 1; }
count_1204="$(el_ledger_count_retro_entries_for .workbench/evolution/ideas-log.md 1204)"
[ "$count_1204" -eq 1 ] || { echo "expected #1204 to stay at exactly 1 retro entry (already covered); found $count_1204" >&2; exit 1; }

el_ledger_has_retro_entry_for .workbench/evolution/ideas-log.md 1207 || {
  echo "no new retrospective audit entry for #1207 (the actual oldest unaudited task after the variant)" >&2
  exit 1
}

# The structural audit marker must also be present — `evolve.sh audited` reads only
# tab-delimited [audit:#NNNN] markers (not free text). If --audit-of was omitted from
# the `evolve.sh log` call, the ledger has the idea text but not the structural marker,
# and future retro-candidates would re-select #1207 instead of skipping it.
bash "$ROOT/scripts/evolve.sh" audited --target . | grep -qE '^1207$' || {
  echo "evolve.sh audited does not list #1207 — structural [audit:#1207] marker missing (--audit-of was not used when logging the retro entry)" >&2
  exit 1
}
exit 0
