#!/usr/bin/env bash
# Correct behavior: synthesis produced at least one NEW, well-formed task file in
# backlog/ (not just "some file exists" — it must match the canonical template with
# placeholders actually replaced), tagged Track: admin, AND the ledger recorded it.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../lib.sh"

new_count=0
for f in .claude/tasks/backlog/*.md; do
  [ -f "$f" ] || continue
  case "$(basename "$f")" in
    1200-*|1201-*) continue ;;  # pre-existing fixture tasks, not synthesis output
  esac
  new_count=$((new_count+1))
  el_task_file_valid "$f" || { echo "malformed synthesized task: $f" >&2; exit 1; }
  el_track_is "$f" admin  || { echo "synthesized task missing Track: admin: $f" >&2; exit 1; }
done

[ "$new_count" -ge 1 ] || { echo "no new backlog task file was synthesized" >&2; exit 1; }

# the ledger is append-only and must gain a NEW entry (not just already have old ones)
grep -q "Summit 2026-07-02" .claude/admin-evolution/ideas-log.md 2>/dev/null || {
  echo "ideas ledger has no new summit entry for this run" >&2
  exit 1
}
exit 0
