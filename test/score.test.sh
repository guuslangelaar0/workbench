#!/usr/bin/env bash
# BM-2 — expectancy scorecard. Deterministic aggregation of the metrics log + ledger into
# expectancy/task, /100k tokens, and a grade — with the honesty rule that a gamed/regressed
# close LOWERS the number.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SC="$HERE/scripts/score.sh"
fail=0
chk() { if eval "$2"; then echo "ok: $1"; else echo "FAIL: $1" >&2; fail=1; fi; }
field() { bash "$SC" --target "$1" 2>/dev/null | sed -n 's/.*EXPECTANCY\/task=\([0-9.]*\).*/\1/p'; }
gradeof() { bash "$SC" --target "$1" 2>/dev/null | sed -n 's/.*grade=\([0-9]*\).*/\1/p'; }

DIR="$(mktemp -d)"
bash "$HERE/scripts/init.sh" --name "Score Co" --level crew --target "$DIR" >/dev/null 2>&1
M="$DIR/.workbench/metrics.tsv"
emit() { printf '%s\t%s\t%s\t-\n' 1 "$1" "${2:--}" >> "$M"; }

# NOTE: capture score output before grep — `cmd | grep -q` under `set -o pipefail`
# spuriously fails when grep matches early and SIGPIPEs the still-writing script.
out() { bash "$SC" --target "$DIR" 2>/dev/null; }

# no data -> graceful
EMPTY="$(out)"
chk "empty: says no resolved tasks" "printf '%s' \"\$EMPTY\" | grep -qi 'No resolved tasks'"
chk "empty: --quiet is 0.0"         "[ \"\$(bash '$SC' --target '$DIR' --quiet)\" = 0.0 ]"

# healthy: 5 closes, 1 bounce, 1 regression, 2 restarts
for i in 1 2 3 4 5; do emit task_closed "000$i"; done
emit task_bounced 0006; emit regression_red; emit restart 0003; emit restart 0004
printf '0001\tclose\t0\t0\tdelta=120000\n0002\tclose\t0\t0\tdelta=80000\n' > "$DIR/.workbench/ledger.tsv"
# net = 5*100 -1*40 -1*80 -2*10 = 360 ; attempts=6 ; per_task=60.0 ; gross=500 ; grade=72 ; /100k = 360/2=180
H="$(out)"
chk "healthy: per-task = 60.0"  "[ \"\$(field '$DIR')\" = 60.0 ]"
chk "healthy: grade = 72"       "[ \"\$(gradeof '$DIR')\" = 72 ]"
chk "healthy: /100k = 180.0"    "printf '%s' \"\$H\" | grep -q 'EXPECTANCY/100k=180.0'"
chk "healthy: win rate 83%"     "printf '%s' \"\$H\" | grep -q '83%'"
chk "healthy: band B"           "printf '%s' \"\$H\" | grep -q 'B (healthy)'"

# a gaming flag must LOWER expectancy (reality, not claims): net 360-150=210 -> per_task 35.0
before="$(field "$DIR")"
emit gaming_flag
after="$(field "$DIR")"
chk "gaming flag drops expectancy" "awk -v a='$after' -v b='$before' 'BEGIN{exit !(a < b)}'"
chk "gaming: per-task now 35.0"    "[ \"\$(field '$DIR')\" = 35.0 ]"

# trend: a second run shows a delta vs the persisted last score
bash "$SC" --target "$DIR" >/dev/null 2>&1   # persist
emit task_closed 0007                         # +1 clean close -> net up
TR="$(out | grep -o 'vs last' || true)"
chk "trend line present on 2nd run" "[ -n '$TR' ]"

# weights are configurable: lowering the game penalty raises expectancy back up
before_cfg="$(field "$DIR")"
python3 - "$DIR/.workbench/config.json" <<'PY'
import json,sys
c=json.load(open(sys.argv[1])); c["score"]={"game":1}; json.dump(c,open(sys.argv[1],'w'),indent=2)
PY
W="$(out)"
chk "config weight honored (game=1)" "printf '%s' \"\$W\" | grep -q 'game=1 '"
chk "lower game weight raises expectancy" "awk -v a=\"\$(field '$DIR')\" -v b='$before_cfg' 'BEGIN{exit !(a > b)}'"

rm -rf "$DIR"
[ "$fail" = 0 ] && echo "PASS: score" || { echo "score test failed"; exit 1; }
