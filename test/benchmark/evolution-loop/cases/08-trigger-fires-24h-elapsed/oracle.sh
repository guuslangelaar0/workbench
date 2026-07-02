#!/usr/bin/env bash
# Correct behavior: a summit ran despite a full backlog, because 24h+ has elapsed. The
# reasoning captured in output must cite elapsed time / staleness, not backlog pressure
# (which was false this round) — proves the model evaluated BOTH legs of the OR
# independently rather than pattern-matching "backlog empty => summit".
set -uo pipefail
grep -q "Summit 2026-07-02" .claude/admin-evolution/ideas-log.md 2>/dev/null || {
  echo "no summit ran despite 24h+ elapsed since last summit" >&2
  exit 1
}
grep -qiE '24.?h|elapsed|since last|quiet period|stale' "$RUN_OUTPUT" 2>/dev/null || {
  echo "run output doesn't indicate the elapsed-time leg of the trigger fired" >&2
  exit 1
}
exit 0
