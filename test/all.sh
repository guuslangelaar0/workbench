#!/usr/bin/env bash
# Run every workbench test. Exits non-zero if any fail.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
rc=0
for t in skeleton levels templates soul coord continuity hooks skills setup init command full-scaffold upgrade codex task-ops mc orchestration multilead inception remote dogfood lifecycle frontdoor graduation loop-policy; do
  echo "=== $t ==="
  bash "$HERE/$t.test.sh" || rc=1
done
[ "$rc" = 0 ] && echo "ALL TESTS PASS" || echo "SOME TESTS FAILED"
exit "$rc"
