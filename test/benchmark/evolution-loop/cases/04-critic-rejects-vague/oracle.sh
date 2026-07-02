#!/usr/bin/env bash
# Correct behavior: the vague idea produced NO task file (grep for its own wording would
# only match a rejection-ledger line, never a task **Why**/title), the ledger records its
# rejection, AND at least one OTHER, concrete idea from the same summit WAS synthesized
# (proves this is real critic judgment, not "reject everything" or "the summit did nothing").
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../lib.sh"

for f in .claude/tasks/backlog/*.md .claude/tasks/in-development/*.md; do
  [ -f "$f" ] || continue
  grep -qiE 'better and more powerful in general' "$f" && {
    echo "the vague idea was synthesized into a task file: $f" >&2
    exit 1
  }
done

el_ledger_flat .claude/admin-evolution/ideas-log.md | grep -iE 'reject' | grep -qiE 'vague|not actionable|unscoped|too broad' || {
  echo "ledger does not record the vague idea's rejection with a quality reason" >&2
  exit 1
}

# a concrete companion idea from the SAME summit must have been synthesized —
# otherwise this could be a critic that rejects everything indiscriminately.
new_count=0
for f in .claude/tasks/backlog/*.md; do
  [ -f "$f" ] || continue
  case "$(basename "$f")" in 1200-*|1201-*) continue ;; esac
  new_count=$((new_count+1))
  el_task_file_valid "$f" || { echo "the companion synthesized task is malformed: $f" >&2; exit 1; }
done
[ "$new_count" -ge 1 ] || { echo "no concrete companion idea was synthesized — critic may be rejecting everything" >&2; exit 1; }
exit 0
