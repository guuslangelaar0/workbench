#!/usr/bin/env bash
# Correct behavior: the REAL `evolve.sh check` output (captured to
# .evolve-check-output by simulate.sh, not a hand-written report) actually says "due
# backlog-low" against the fixture's real state, a summit actually ran off that real
# branch (new ledger heading + new backlog task), and the run output attributes it to
# backlog pressure specifically — not staleness (which is false here: last-summit is
# only ~14h old per the fixture's real epoch stamp). An implementation that pattern-
# matches the prompt's disclosed wording instead of running the real trigger would
# still produce a plausible-sounding report; checking the actual command's own exit
# line closes that gap.
set -uo pipefail
[ -f .evolve-check-output ] || { echo "no .evolve-check-output captured — evolve.sh check was not actually invoked" >&2; exit 1; }
check_line1="$(head -1 .evolve-check-output)"
case "$check_line1" in
  due\ backlog-low) : ;;
  due*) : ;;  # any due-reason still counts as "fires", but assert the specific reason below
  *) echo "evolve.sh check's real first line was '$check_line1', not 'due ...' — trigger did not actually fire" >&2; exit 1 ;;
esac
printf '%s' "$check_line1" | grep -qi 'backlog-low' || {
  echo "evolve.sh check fired for a reason other than backlog-low ('$check_line1') — this case's fixture state should only trip the backlog leg" >&2
  exit 1
}

grep -q "Summit — 2026-07-02" .workbench/evolution/ideas-log.md 2>/dev/null || {
  echo "no summit ran despite evolve.sh check reporting due backlog-low" >&2
  exit 1
}

grep -qiE 'backlog|threshold|queue' "$RUN_OUTPUT" 2>/dev/null || {
  echo "run output doesn't indicate the backlog-pressure leg of the trigger fired" >&2
  exit 1
}
# the elapsed-time leg was NOT the reason here — a report that instead cites staleness
# would suggest the model reasoned about the wrong leg (or didn't reason at all).
grep -qiE '24.?h.{0,10}elapsed|summit-stale|stale' "$RUN_OUTPUT" 2>/dev/null && {
  echo "run output cites the elapsed-time leg, but that leg is false in this scenario (last-summit ~14h old)" >&2
  exit 1
}
exit 0
