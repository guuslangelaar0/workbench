#!/usr/bin/env bash
# SQ-7 — task dependency graph. **Blocked-by:** <ids>; a task is ready when its deps are
# in verified/shipped. ready/blocked listing + cycle detection.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEPS="$HERE/scripts/deps.sh"
fail=0
chk() { if eval "$2"; then echo "ok: $1"; else echo "FAIL: $1" >&2; fail=1; fi; }

DIR="$(mktemp -d)"
bash "$HERE/scripts/init.sh" --name "Dep Co" --level crew --target "$DIR" >/dev/null 2>&1
NEW="$HERE/scripts/task-new.sh"; MV="$HERE/scripts/task-move.sh"

# template carries the field, task-new threads --blocked-by
bash "$NEW" --target "$DIR" --title "base" >/dev/null 2>&1
bash "$NEW" --target "$DIR" --title "needs base" --blocked-by "0001" >/dev/null 2>&1
bash "$NEW" --target "$DIR" --title "needs two" --blocked-by "0001, 0002" >/dev/null 2>&1
chk "template has Blocked-by field" "grep -hq '^\*\*Blocked-by:\*\* 0001' \"\$(ls '$DIR/.claude/tasks/backlog/0002'*.md)\""

# 0002 blocked by 0001 (still in backlog) -> blocked
chk "status: 0002 blocked"       "bash '$DEPS' status 0002 --target '$DIR' | grep -q 'blocked-by: 0001'"
# ready list: only 0001 (no deps)
chk "ready: only 0001"           "[ \"\$(bash '$DEPS' ready --target '$DIR' | tr '\n' ' ')\" = '0001 ' ]"

# verify 0001 -> 0002 becomes ready; 0003 still blocked by 0002
WB_SKIP_VERIFY_GATE=1 bash "$MV" 0001 verified --target "$DIR" >/dev/null 2>&1
chk "after verify 0001: 0002 ready" "[ \"\$(bash '$DEPS' status 0002 --target '$DIR')\" = ready ]"
chk "0003 still blocked by 0002"    "bash '$DEPS' status 0003 --target '$DIR' | grep -q 'blocked-by: 0002'"
chk "ready list now includes 0002"  "bash '$DEPS' ready --target '$DIR' | grep -q '^0002\$'"
chk "ready list excludes 0003"      "! bash '$DEPS' ready --target '$DIR' | grep -q '^0003\$'"

# blocked report names the unmet dep
chk "blocked report: 0003 -> 0002"  "bash '$DEPS' blocked --target '$DIR' | grep -q '^0003 blocked-by: 0002'"

# no cycle yet
chk "cycles: none (exit 0)"      "bash '$DEPS' cycles --target '$DIR' >/dev/null 2>&1"

# introduce a cycle: make 0002 blocked-by 0003 (0003 already blocked-by 0002)
f2="$(ls "$DIR/.claude/tasks"/*/0002-*.md 2>/dev/null | head -1)"
sed -i 's/^\*\*Blocked-by:\*\* .*/**Blocked-by:** 0003/' "$f2"
chk "cycles: detected (exit 3)"  "! bash '$DEPS' cycles --target '$DIR' >/dev/null 2>&1"
# capture first — the command exits 3, and `cmd | grep` under pipefail returns 3 even on a match
CYC="$(bash "$DEPS" cycles --target "$DIR" 2>&1 || true)"
chk "cycles: prints 'cycle'"     "printf '%s' \"\$CYC\" | grep -qi cycle"

rm -rf "$DIR"
[ "$fail" = 0 ] && echo "PASS: deps" || { echo "deps test failed"; exit 1; }
