#!/usr/bin/env bash
# Correct behavior: the REAL `evolve.sh check` output (captured to
# .evolve-check-output by simulate.sh) actually says "due summit-stale" against the
# variant's real state, a summit actually ran off that real branch, and the run
# output attributes it to elapsed time — not backlog pressure (which is false this
# round: the variant filled backlog to 5, well above queue_low_water=3). Checking the
# actual command's own exit line (not a hand-written report) closes the gap where a
# model pattern-matches the prompt's disclosed wording instead of running the real
# trigger.
set -uo pipefail
[ -f .evolve-check-output ] || { echo "no .evolve-check-output captured — evolve.sh check was not actually invoked" >&2; exit 1; }
check_line1="$(head -1 .evolve-check-output)"
case "$check_line1" in
  due*) : ;;
  *) echo "evolve.sh check's real first line was '$check_line1', not 'due ...' — trigger did not actually fire" >&2; exit 1 ;;
esac
printf '%s' "$check_line1" | grep -qi 'summit-stale' || {
  echo "evolve.sh check fired for a reason other than summit-stale ('$check_line1') — this case's fixture state should only trip the elapsed-time leg" >&2
  exit 1
}

grep -q "Summit — 2026-07-02" .workbench/evolution/ideas-log.md 2>/dev/null || {
  echo "no summit ran despite evolve.sh check reporting due summit-stale" >&2
  exit 1
}

grep -qiE '24.?h|elapsed|since last|quiet period|stale' "$RUN_OUTPUT" 2>/dev/null || {
  echo "run output doesn't indicate the elapsed-time leg of the trigger fired" >&2
  exit 1
}
# backlog pressure was NOT the reason here — a report that instead cites backlog/
# threshold would suggest the model reasoned about the wrong leg (or didn't reason at
# all, just pattern-matched "a summit ran => say something plausible").
grep -qiE 'backlog.{0,20}(low|below|threshold)' "$RUN_OUTPUT" 2>/dev/null && {
  echo "run output cites backlog pressure, but that leg is false in this scenario (backlog filled to 5, above queue_low_water=3)" >&2
  exit 1
}
exit 0
