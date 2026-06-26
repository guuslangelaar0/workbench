#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail=0
chk() { if eval "$2"; then echo "ok: $1"; else echo "FAIL: $1" >&2; fail=1; fi; }

T1="$(mktemp -d)"; bash "$HERE/scripts/init.sh" --profile full --level solo  --name S --mission m --target "$T1" >/dev/null 2>&1
chk "solo: no in-review dir"   "[ ! -d '$T1/.claude/tasks/in-review' ]"
chk "solo: has verified dir"   "[ -d '$T1/.claude/tasks/verified' ]"
chk "solo: config level=solo"  "grep -q '\"level\": \"solo\"' '$T1/.workbench/config.json'"
chk "solo: dials present"      "grep -q '\"loop_autonomy\": \"auto-continue\"' '$T1/.workbench/config.json'"

T2="$(mktemp -d)"; bash "$HERE/scripts/init.sh" --profile full --level fleet --name F --mission m --target "$T2" >/dev/null 2>&1
chk "fleet: has release-candidate dir" "[ -d '$T2/.claude/tasks/release-candidate' ]"
chk "fleet: has staged dir"            "[ -d '$T2/.claude/tasks/staged' ]"
rm -rf "$T1" "$T2"

# C1: task-move.sh validates stages against the project's level lifecycle
T3="$(mktemp -d)"; bash "$HERE/scripts/init.sh" --profile full --level crew --name C --mission m --target "$T3" >/dev/null 2>&1
bash "$HERE/scripts/task-new.sh" --target "$T3" --title "Ship me" >/dev/null 2>&1
id="$(ls "$T3/.claude/tasks/backlog" | head -1 | sed 's/-.*//')"
bash "$HERE/scripts/task-move.sh" --target "$T3" "$id" staged >/dev/null 2>&1
chk "crew: task moved to staged"  "ls '$T3/.claude/tasks/staged/' | grep -q \"$id\""
chk "crew: status line synced"    "grep -qi 'Status:.*staged' \"\$(ls '$T3/.claude/tasks/staged/'*.md | head -1)\""
T4="$(mktemp -d)"; bash "$HERE/scripts/init.sh" --profile full --level solo --name So --mission m --target "$T4" >/dev/null 2>&1
bash "$HERE/scripts/task-new.sh" --target "$T4" --title "x" >/dev/null 2>&1
sid="$(ls "$T4/.claude/tasks/backlog" | head -1 | sed 's/-.*//')"
chk "solo: staged is rejected" "! bash \"$HERE/scripts/task-move.sh\" --target \"$T4\" \"$sid\" staged >/dev/null 2>&1"
rm -rf "$T3" "$T4"

[ "$fail" = 0 ] && echo "PASS: lifecycle" || { echo "lifecycle test failed"; exit 1; }
