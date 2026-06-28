#!/usr/bin/env bash
# Run every workbench test. Exits non-zero if any fail.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
rc=0
for t in skeleton levels templates soul coord continuity hooks skills setup init command full-scaffold upgrade codex task-ops epics mc orchestration multilead inception remote remote-guard dogfood lifecycle frontdoor graduation detect-level marketplace architecture arch-drift verification-gate lane watchdog loop-policy suggest gate-integrity budget cross-model suggest-scan regression-gate deps; do
  echo "=== $t ==="
  bash "$HERE/$t.test.sh" || rc=1
done
[ "$rc" = 0 ] && echo "ALL TESTS PASS" || echo "SOME TESTS FAILED"
exit "$rc"
