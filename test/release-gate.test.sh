#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
R="$HERE/scripts/release-gate.sh"
fail=0
chk() { if eval "$2"; then echo "ok: $1"; else echo "FAIL: $1" >&2; fail=1; fi; }

chk "release gate script exists" "[ -f '$R' ]"
chk "release gate script executable" "[ -x '$R' ]"
chk "release gate syntactically valid" "bash -n '$R'"
chk "release gate help documents live" "bash '$R' --help 2>&1 | grep -q -- '--live'"
DRY_OFFLINE="$(bash "$R" --dry-run --skip-suite --skip-rust 2>&1)"
DRY_LIVE="$(bash "$R" --dry-run --live --skip-suite --skip-rust 2>&1)"
chk "release gate dry-run names offline gates" "printf '%s' \"\$DRY_OFFLINE\" | grep -q 'scripts/bench.sh'"
chk "release gate dry-run names live gates" "printf '%s' \"\$DRY_LIVE\" | grep -q 'test/e2e/run.sh' && printf '%s' \"\$DRY_LIVE\" | grep -q 'WB_BENCH=1' && printf '%s' \"\$DRY_LIVE\" | grep -q 'bench-intents.sh'"
chk "release gate live refuses skipped e2e" "WB_RELEASE_E2E_CMD='printf \"SKIP: live-plugin e2e tests are gated\\n\"' WB_RELEASE_BENCH_LIVE_CMD='printf \"BENCH-INTENT [set=all] conformance=1/1  expectancy=100  grade=100/100\\nbench: OK\\n\"' bash '$R' --live --skip-suite --skip-rust --skip-offline-bench --no-evidence >/dev/null 2>&1; [ \$? -ne 0 ]"
chk "release gate live requires perfect live bench" "WB_RELEASE_E2E_CMD='printf \"E2E PASS (3 checks)\\n\"' WB_RELEASE_BENCH_LIVE_CMD='printf \"BENCH-INTENT [set=all] conformance=1/2  expectancy=50  grade=50/100\\nbench: OK\\n\"' bash '$R' --live --skip-suite --skip-rust --skip-offline-bench --no-evidence >/dev/null 2>&1; [ \$? -ne 0 ]"
chk "release gate live accepts proven live outputs" "WB_RELEASE_E2E_CMD='printf \"E2E PASS (3 checks)\\n\"' WB_RELEASE_BENCH_LIVE_CMD='printf \"BENCH-INTENT [set=all] conformance=2/2  expectancy=100  grade=100/100\\nbench: OK\\n\"' bash '$R' --live --skip-suite --skip-rust --skip-offline-bench --no-evidence >/dev/null 2>&1"
chk "release gate evidence is gitignored" "grep -q '/.workbench/release/' '$HERE/.gitignore'"

[ "$fail" = 0 ] && echo "PASS: release-gate" || { echo "release-gate test failed"; exit 1; }
