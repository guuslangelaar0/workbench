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
[ "$fail" = 0 ] && echo "PASS: lifecycle" || { echo "lifecycle test failed"; exit 1; }
