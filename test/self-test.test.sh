#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail=0
chk() { if eval "$2"; then echo "ok: $1"; else echo "FAIL: $1" >&2; fail=1; fi; }

chk "self-test script exists" "[ -f '$HERE/scripts/self-test.sh' ]"
chk "self-test command exists" "[ -f '$HERE/commands/self-test.md' ]"
chk "self-test references all suite" "grep -q 'test/all.sh' '$HERE/scripts/self-test.sh'"
chk "self-test validates root marketplace" "grep -q '.claude-plugin/marketplace.json' '$HERE/scripts/self-test.sh'"
chk "self-test runs publishability validator" "grep -q 'validate-plugin.sh' '$HERE/scripts/self-test.sh'"
chk "self-test skip-suite runs" "bash '$HERE/scripts/self-test.sh' --skip-suite >/dev/null 2>&1"

[ "$fail" = 0 ] && echo "PASS: self-test" || { echo "self-test test failed"; exit 1; }
