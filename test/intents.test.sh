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

# fixture sanity — count-agnostic so new cases don't break the test
N="$(find "$CASES" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
chk "at least 11 intent cases"   "[ '$N' -ge 11 ]"
for c in "$CASES"/*/; do
  id="$(basename "$c")"
  chk "$id has prompt+oracle+sim"  "[ -f '$c/prompt' ] && [ -f '$c/oracle.sh' ] && [ -f '$c/simulate.sh' ]"
done
# level coverage: cases exist across solo/pair/crew/fleet (level-conditioned behavior)
for lv in solo pair crew fleet; do
  chk "has a $lv case"           "grep -rqx '$lv' '$CASES'/*/level"
done

# the whole harness, offline: every case's correct behavior must score (N/N)
SIM="$(bash "$BI" --simulate 2>/dev/null)"
chk "simulate: $N/$N conformance" "printf '%s' \"\$SIM\" | grep -q 'conformance=$N/$N'"
chk "simulate: grade 100"        "printf '%s' \"\$SIM\" | grep -q 'grade=100/100'"

# --only selects a single case
ONE="$(bash "$BI" --simulate --only 01-bug-autofile 2>/dev/null)"
chk "--only runs one case"       "printf '%s' \"\$ONE\" | grep -q 'conformance=1/1'"

# --set train|holdout partitions the cases (held-out split for BM-6 anti-overfit).
# every case has a `set` file; train+holdout must sum to the full count, both must pass.
for c in "$CASES"/*/; do chk "$(basename "$c") has a set file" "[ -f '$c/set' ]"; done
TR="$(bash "$BI" --simulate --set train 2>/dev/null)"
HO="$(bash "$BI" --simulate --set holdout 2>/dev/null)"
tr_n="$(printf '%s' "$TR" | sed -n 's/.*conformance=\([0-9]*\)\/\([0-9]*\).*/\2/p')"
ho_n="$(printf '%s' "$HO" | sed -n 's/.*conformance=\([0-9]*\)\/\([0-9]*\).*/\2/p')"
chk "train+holdout = full set" "[ \$(( ${tr_n:-0} + ${ho_n:-0} )) -eq '$N' ]"
chk "holdout is non-empty"     "[ '${ho_n:-0}' -ge 1 ]"
chk "train set fully passes"   "printf '%s' \"\$TR\" | grep -q 'conformance=${tr_n}/${tr_n}'"
chk "holdout set fully passes" "printf '%s' \"\$HO\" | grep -q 'conformance=${ho_n}/${ho_n}'"
chk "--set rejects bad value"  "bash '$BI' --simulate --set bogus >/dev/null 2>&1; [ \$? -eq 64 ]"

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

FAKEBIN="$(mktemp -d "${TMPDIR:-/tmp}/bench-intents-fakebin.XXXXXX")"
cat > "$FAKEBIN/claude" <<'SH'
#!/usr/bin/env bash
sleep 3
printf 'late fake claude output\n'
SH
chmod +x "$FAKEBIN/claude"
T0="$(date +%s)"
TOUT="$(WB_BENCH=1 WB_BENCH_TIMEOUT=1 PATH="$FAKEBIN:$PATH" bash "$BI" --only 01-bug-autofile 2>&1)"
TRC=$?
T1="$(date +%s)"
ELAPSED=$((T1-T0))
chk "live case timeout does not hang" "[ $TRC -eq 0 ] && [ $ELAPSED -lt 4 ] && printf '%s' \"\$TOUT\" | grep -q 'TIMEOUT'"
rm -rf "$FAKEBIN"

# live path refuses without WB_BENCH=1
chk "live refuses (exit 2)"      "bash '$BI' >/dev/null 2>&1; [ \$? -eq 2 ]"

[ "$fail" = 0 ] && echo "PASS: intents" || { echo "intents test failed"; exit 1; }
