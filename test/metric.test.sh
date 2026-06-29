#!/usr/bin/env bash
# BM-1 — metrics event log. metric.sh appends durable event lines; the existing gates
# emit the right events (task_closed/task_bounced/gaming_flag/regression_red/restart/drift_due).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
M="$HERE/scripts/metric.sh"
fail=0
chk() { if eval "$2"; then echo "ok: $1"; else echo "FAIL: $1" >&2; fail=1; fi; }
ev() { cut -f2 "$1/.workbench/metrics.tsv" 2>/dev/null; }   # event column

DIR="$(mktemp -d)"
bash "$HERE/scripts/init.sh" --name "Met Co" --level crew --target "$DIR" >/dev/null 2>&1
LOG="$DIR/.workbench/metrics.tsv"

# direct emit appends a 4-col line
bash "$M" emit task_closed --task 0001 --detail "x->verified" --target "$DIR"
chk "emit: line appended"        "[ -f '$LOG' ]"
chk "emit: 4 tab-separated cols"  "[ \"\$(awk -F'\t' 'NR==1{print NF}' '$LOG')\" = 4 ]"
chk "emit: event recorded"        "ev '$DIR' | grep -q '^task_closed\$'"

# fail-open: emit outside a workbench project is a silent no-op (exit 0)
ND="$(mktemp -d)"
chk "emit: no project -> exit 0"  "bash '$M' emit task_closed --target '$ND'; [ \$? -eq 0 ]"
chk "emit: no project -> no file" "[ ! -f '$ND/.workbench/metrics.tsv' ]"
rm -rf "$ND"

# --- wiring ---
NEW="$HERE/scripts/task-new.sh"; MV="$HERE/scripts/task-move.sh"
: > "$LOG"   # reset

# task-move: verify -> task_closed
bash "$NEW" --target "$DIR" --title "winner" >/dev/null 2>&1
id="$(ls "$DIR/.claude/tasks/backlog" | head -1 | sed 's/-.*//')"
WB_SKIP_VERIFY_GATE=1 bash "$MV" "$id" verified --target "$DIR" >/dev/null 2>&1
chk "task-move: verified -> task_closed" "ev '$DIR' | grep -q '^task_closed\$'"

# task-move: in-review -> in-development = bounce
bash "$NEW" --target "$DIR" --title "rework" >/dev/null 2>&1
id2="$(ls "$DIR/.claude/tasks/backlog" | head -1 | sed 's/-.*//')"
bash "$MV" "$id2" in-review --target "$DIR" >/dev/null 2>&1
: > "$LOG"
bash "$MV" "$id2" in-development --target "$DIR" >/dev/null 2>&1
chk "task-move: review->dev = task_bounced" "ev '$DIR' | grep -q '^task_bounced\$'"

# gate-integrity hard signal -> gaming_flag
: > "$LOG"
printf 'diff --git a/t_test.rs b/t_test.rs\n--- a/t_test.rs\n+++ b/t_test.rs\n@@\n+  assert!(true);\n' > "$DIR/g.diff"
bash "$HERE/scripts/gate-integrity.sh" --diff "$DIR/g.diff" --target "$DIR" >/dev/null 2>&1
chk "gate-integrity -> gaming_flag" "ev '$DIR' | grep -q '^gaming_flag\$'"

# regression-gate red -> regression_red
: > "$LOG"
python3 - "$DIR/.workbench/config.json" '["false"]' <<'PY'
import json,sys
c=json.load(open(sys.argv[1])); c.setdefault("project",{})["checks"]=json.loads(sys.argv[2]); json.dump(c,open(sys.argv[1],'w'),indent=2)
PY
bash "$HERE/scripts/regression-gate.sh" --target "$DIR" >/dev/null 2>&1
chk "regression-gate -> regression_red" "ev '$DIR' | grep -q '^regression_red\$'"

# value-audit due -> drift_due
: > "$LOG"
for i in 1 2 3 4 5 6; do printf '# %04d — f\n' "$i" > "$DIR/.claude/tasks/verified/$(printf %04d $i)-f.md"; done
bash "$HERE/scripts/value-audit.sh" check --cadence 3 --target "$DIR" >/dev/null 2>&1
chk "value-audit -> drift_due"    "ev '$DIR' | grep -q '^drift_due\$'"

# lane restart (2nd start) -> restart
: > "$LOG"
bash "$HERE/scripts/lane.sh" start 0009 --owner eng --target "$DIR" >/dev/null 2>&1
bash "$HERE/scripts/lane.sh" start 0009 --owner eng --target "$DIR" >/dev/null 2>&1
chk "lane 2nd start -> restart"   "ev '$DIR' | grep -q '^restart\$'"

rm -rf "$DIR"
[ "$fail" = 0 ] && echo "PASS: metric" || { echo "metric test failed"; exit 1; }
