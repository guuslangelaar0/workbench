#!/usr/bin/env bash
# CB-4 — the cadence-convenience wrapper. It composes already-tested scripts, so this is a
# light smoke: the free path runs the structural gate + offline conformance and reports OK,
# the live step is skipped without WB_BENCH=1, and a bad arg is rejected.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
B="$ROOT/scripts/bench.sh"
fail=0
chk() { if eval "$2"; then echo "ok: $1"; else echo "FAIL: $1" >&2; fail=1; fi; }

OUT="$(bash "$B" 2>&1)"; rc=$?
chk "free run exits 0"           "[ $rc -eq 0 ]"
chk "runs the expectancy gate"   "printf '%s' \"\$OUT\" | grep -q 'expectancy gate'"
chk "runs offline conformance"   "printf '%s' \"\$OUT\" | grep -q 'BENCH-INTENT'"
chk "skips live without WB_BENCH" "printf '%s' \"\$OUT\" | grep -q 'LIVE — skipped'"
chk "reports OK"                 "printf '%s' \"\$OUT\" | grep -q 'bench: OK'"
chk "rejects bad arg (exit 64)"  "bash '$B' --bogus >/dev/null 2>&1; [ \$? -eq 64 ]"

# --set is threaded through to the conformance harness
HO="$(bash "$B" --set holdout 2>&1)"
chk "--set holdout threads through" "printf '%s' \"\$HO\" | grep -q 'set=holdout'"

# the how-to doc exists and links the design
chk "benchmarking.md present"    "[ -f '$ROOT/docs/benchmarking.md' ]"
chk "doc links the design"       "grep -q 'self-benchmarking-expectancy-design' '$ROOT/docs/benchmarking.md'"

[ "$fail" = 0 ] && echo "PASS: bench" || { echo "bench test failed"; exit 1; }
