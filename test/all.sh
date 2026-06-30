#!/usr/bin/env bash
# Run every workbench test. Exits non-zero if any fail.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
rc=0
for t in skeleton levels templates soul coord continuity hooks skills setup init command full-scaffold upgrade uninstall doctor self-test codex task-ops lead-purpose park epics mc orchestration multilead inception remote remote-guard dogfood lifecycle frontdoor graduation detect-level marketplace architecture arch-drift verification-gate lane watchdog loop-policy suggest gate-integrity budget cross-model suggest-scan regression-gate deps value-audit metric score benchmark intents expectancy-gate knobs bench; do
  echo "=== $t ==="
  bash "$HERE/$t.test.sh" || rc=1
done
[ "$rc" = 0 ] && echo "ALL TESTS PASS" || echo "SOME TESTS FAILED"
exit "$rc"
