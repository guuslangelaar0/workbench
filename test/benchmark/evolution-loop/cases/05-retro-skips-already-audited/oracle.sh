#!/usr/bin/env bash
# Correct behavior: exactly ONE new "retrospective audit of task #NNNN" ledger entry
# was added this summit, and it targets #1203 (the oldest verified/shipped admin task
# WITHOUT a prior retro entry) — NOT #1204, which the fixture already covered on
# 2026-06-18. A mechanism that doesn't actually grep the ledger would re-audit #1204
# (it's "shipped" and superficially looks auditable) or audit both/neither.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../lib.sh"

# must NOT contain a second, distinct retro entry for #1204 (i.e. more than the
# one pre-existing 2026-06-18 entry the fixture seeded)
count_1204="$(el_ledger_count_retro_entries_for .claude/admin-evolution/ideas-log.md 1204)"
[ "$count_1204" -eq 1 ] || { echo "expected exactly 1 retro entry for #1204 (the pre-existing one); found $count_1204 — task #1204 was re-audited" >&2; exit 1; }

el_ledger_has_retro_entry_for .claude/admin-evolution/ideas-log.md 1203 || {
  echo "no new retrospective audit entry for #1203 (the oldest unaudited admin task)" >&2
  exit 1
}
exit 0
