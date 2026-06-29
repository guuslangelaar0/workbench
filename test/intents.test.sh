#!/usr/bin/env bash
# BM-8 — intent→behavior conformance benchmark. Verified OFFLINE (no LLM): the --simulate
# path fakes each case's CORRECT behavior via the plugin's own scripts and every oracle must
# pass; the oracles must also FAIL when the behavior is absent (so they actually discriminate).
# The live path (claude -p, always the user's real model) is gated by WB_BENCH=1.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BI="$ROOT/scripts/bench-intents.sh"; CASES="$ROOT/test/benchmark/intents/cases"
fail=0
chk() { if eval "$2"; then echo "ok: $1"; else echo "FAIL: $1" >&2; fail=1; fi; }

# fixture sanity
chk "5 intent cases"             "[ \"\$(find '$CASES' -mindepth 1 -maxdepth 1 -type d | wc -l)\" = 5 ]"
for c in 01-bug-autofile 02-feature-suggests 03-status-mc 04-new-task 05-verify-gate-holds; do
  chk "$c has prompt+oracle+sim"  "[ -f '$CASES/$c/prompt' ] && [ -f '$CASES/$c/oracle.sh' ] && [ -f '$CASES/$c/simulate.sh' ]"
done

# the whole harness, offline: every case's correct behavior must score
SIM="$(bash "$BI" --simulate 2>/dev/null)"
chk "simulate: 5/5 conformance"  "printf '%s' \"\$SIM\" | grep -q 'conformance=5/5'"
chk "simulate: grade 100"        "printf '%s' \"\$SIM\" | grep -q 'grade=100/100'"

# --only selects a single case
ONE="$(bash "$BI" --simulate --only 01-bug-autofile 2>/dev/null)"
chk "--only runs one case"       "printf '%s' \"\$ONE\" | grep -q 'conformance=1/1'"

# oracles DISCRIMINATE: each must FAIL on a fresh project where the behavior never happened
P="$(mktemp -d)"; bash "$ROOT/scripts/init.sh" --name X --level crew --target "$P" >/dev/null 2>&1
: > "$P/.run-output"
for c in 01-bug-autofile 02-feature-suggests 03-status-mc 04-new-task; do
  chk "oracle $c fails on empty project" "! ( cd '$P' && RUN_OUTPUT='$P/.run-output' bash '$CASES/$c/oracle.sh' ) >/dev/null 2>&1"
done
# 05 (verify-gate-holds) PASSES on empty (nothing in verified = gate held) — that's correct
chk "oracle 05 passes when nothing verified" "( cd '$P' && RUN_OUTPUT='$P/.run-output' bash '$CASES/05-verify-gate-holds/oracle.sh' )"
# ...and FAILS if a task is forced into verified with placeholder evidence (gate bypassed)
bash "$ROOT/scripts/task-new.sh" --target "$P" --state in-development --title "forced" >/dev/null 2>&1
fid="$(ls "$P/.claude/tasks/in-development" | head -1 | sed 's/-.*//')"
WB_SKIP_VERIFY_GATE=1 bash "$ROOT/scripts/task-move.sh" "$fid" verified --target "$P" >/dev/null 2>&1
chk "oracle 05 catches bypassed gate" "! ( cd '$P' && RUN_OUTPUT='$P/.run-output' bash '$CASES/05-verify-gate-holds/oracle.sh' ) >/dev/null 2>&1"
rm -rf "$P"

# live path refuses without WB_BENCH=1
chk "live refuses (exit 2)"      "bash '$BI' >/dev/null 2>&1; [ \$? -eq 2 ]"

[ "$fail" = 0 ] && echo "PASS: intents" || { echo "intents test failed"; exit 1; }
