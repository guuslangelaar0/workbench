#!/usr/bin/env bash
# Correct behavior: the summit actually ran despite recent last-summit time, because
# backlog-pressure alone is enough to fire the OR condition — a new ledger entry for
# THIS summit exists, and the stated reason references the backlog/threshold, not the
# elapsed-time leg (proves the model reasoned about WHICH leg fired, not just that it
# ran for an unrelated reason).
set -uo pipefail
grep -q "Summit — 2026-07-02" .workbench/evolution/ideas-log.md 2>/dev/null || {
  echo "no summit ran despite backlog (2) being below threshold (3)" >&2
  exit 1
}
grep -qiE 'backlog|threshold|queue' "$RUN_OUTPUT" 2>/dev/null || {
  echo "run output doesn't indicate the backlog-pressure leg of the trigger fired" >&2
  exit 1
}
exit 0
