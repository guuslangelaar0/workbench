#!/usr/bin/env bash
# Correct behavior: synthesis produced at least one NEW, well-formed task file in
# backlog/ (not just "some file exists" — it must match the canonical template with
# placeholders actually replaced), tagged Track: admin, AND the ledger shows evidence
# the FULL mechanism ran, not just "one fabricated task + a heading":
#   - a NEW "## Summit — <today>" heading exists (record-summit actually ran)
#   - MULTIPLE personas (not just the one synthesizing persona) have a logged
#     disposition this summit — a stub that only ever produces the single synthesized
#     task with nothing else would fail this
#   - the synthesized task's content is TRACEABLE to a specific persona's ledger
#     entry — the ledger names the same persona (billing-ops) and the entry text
#     overlaps the task title (proves the task didn't just appear from nowhere; a
#     particular persona's proposal became a particular task)
#   - the ledger separately records a retrospective disposition (the OTHER mandate a
#     real summit runs alongside generation) for one of the fixture's genuine
#     retro-candidates (#1203 or #1204), not just the synthesis path
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../lib.sh"

new_ids=""
new_count=0
for f in .claude/tasks/backlog/*.md; do
  [ -f "$f" ] || continue
  case "$(basename "$f")" in
    1200-*|1201-*) continue ;;  # pre-existing fixture tasks, not synthesis output
  esac
  new_count=$((new_count+1))
  el_task_file_valid "$f" || { echo "malformed synthesized task: $f" >&2; exit 1; }
  el_track_is "$f" admin  || { echo "synthesized task missing Track: admin: $f" >&2; exit 1; }
  new_id="$(basename "$f" | grep -oE '^[0-9]+')"
  new_ids="$new_ids $new_id"
done

[ "$new_count" -ge 1 ] || { echo "no new backlog task file was synthesized" >&2; exit 1; }

# the ledger is append-only and must gain a NEW summit heading (not just already have old ones)
grep -q "Summit — 2026-07-02" .workbench/evolution/ideas-log.md 2>/dev/null || {
  echo "ideas ledger has no new summit entry for this run" >&2
  exit 1
}

# extract only THIS run's new ledger lines (after the last pre-existing summit heading
# the fixture seeded, i.e. everything from the first NEW "## Summit —" onward)
new_ledger_lines="$(awk '/^## Summit — 2026-07-02/{ found=1 } found' .workbench/evolution/ideas-log.md)"
[ -n "$new_ledger_lines" ] || { echo "no ledger lines follow the new summit heading" >&2; exit 1; }

# an implementation that only ever produces the ONE synthesized entry (nothing for any
# other persona) has not actually convened a multi-persona panel — require ledger
# entries this summit for at least 2 DISTINCT personas.
persona_count="$(printf '%s\n' "$new_ledger_lines" | grep -E '^- \[' | sed -E 's/^- \[[0-9-]+\] ([^—]+) —.*/\1/' | sed 's/[[:space:]]*$//' | sort -u | wc -l | tr -d ' ')"
[ "$persona_count" -ge 2 ] || {
  echo "only $persona_count distinct persona(s) logged this summit — no evidence multiple personas actually convened (a fabricated single task + heading would look like this)" >&2
  exit 1
}

# the synthesized task must be traceable to a SPECIFIC persona's ledger entry: find
# the queued-task ledger line for one of the new ids, confirm it names a persona, and
# confirm that persona's idea text overlaps the actual task title/why — not just a
# structurally-valid task conjured with no logged provenance.
traced=0
for id in $new_ids; do
  queue_line="$(printf '%s\n' "$new_ledger_lines" | grep -E "^- \[" | grep -E "queued as task #${id}\b")"
  [ -n "$queue_line" ] || continue
  persona="$(printf '%s' "$queue_line" | sed -E 's/^- \[[0-9-]+\] ([^—]+) —.*/\1/' | sed 's/[[:space:]]*$//')"
  [ -n "$persona" ] || continue
  idea_text="$(printf '%s' "$queue_line" | sed -E 's/^- \[[0-9-]+\] [^—]+ — (.*) — [^—]+$/\1/')"
  f="$(ls .claude/tasks/backlog/${id}-*.md 2>/dev/null | head -1)"
  [ -n "$f" ] || continue
  # crude but real overlap check: at least one distinctive word (4+ chars) from the
  # ledger's idea text appears in the task file's title/body
  overlap=0
  for w in $(printf '%s' "$idea_text" | tr '[:upper:]' '[:lower:]' | grep -oE '[a-z]{4,}'); do
    grep -qi "$w" "$f" && { overlap=1; break; }
  done
  [ "$overlap" = 1 ] && { traced=1; break; }
done
[ "$traced" = 1 ] || {
  echo "no synthesized task could be traced to a specific persona's logged ledger proposal" >&2
  exit 1
}

# the retrospective mandate must ALSO have produced a STRUCTURAL ledger entry this
# summit for the correct candidate: #1203 (oldest verified/shipped task without a prior
# [audit:#NNNN] marker). #1204 is already audited in the fixture (structural
# [audit:#1204] entry from 2026-06-18) so it must NOT be re-picked.
# Checking the structural [audit:#1203] marker (not free-text idea content) ensures
# the evolve.sh log --audit-of path was actually used — only that writes the
# tab-delimited marker that _audited_ids / retro-candidates count for coverage rotation.
printf '%s\n' "$new_ledger_lines" | grep -qE '\[audit:#1203\]' || {
  echo "no structural [audit:#1203] marker in the new summit's ledger — either the wrong candidate was picked or evolve.sh log was called without --audit-of (free-text idea content is not sufficient for coverage tracking)" >&2
  exit 1
}
# Also confirm evolve.sh audited now lists 1203 — structural marker must be parseable.
bash "$ROOT/scripts/evolve.sh" audited --target . | grep -qE '^1203$' || {
  echo "evolve.sh audited does not list #1203 despite [audit:#1203] appearing in the ledger — marker format mismatch" >&2
  exit 1
}
exit 0
