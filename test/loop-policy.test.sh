#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail=0
chk() { if eval "$2"; then echo "ok: $1"; else echo "FAIL: $1" >&2; fail=1; fi; }

S="$(mktemp -d)"; bash "$HERE/scripts/init.sh" --profile full --level solo  --name S --mission m --target "$S" >/dev/null 2>&1
C="$(mktemp -d)"; bash "$HERE/scripts/init.sh" --profile full --level crew  --name C --mission m --target "$C" >/dev/null 2>&1
chk "solo -> auto-continue" "[ \"\$(bash \"$HERE/scripts/loop-policy.sh\" \"$S\")\" = auto-continue ]"
chk "crew -> suggest-wait"  "[ \"\$(bash \"$HERE/scripts/loop-policy.sh\" \"$C\")\" = suggest-wait ]"
# dial override beats the level preset
sed -i 's/"loop_autonomy": "auto-continue"/"loop_autonomy": "suggest-wait"/' "$S/.workbench/config.json"
chk "override beats preset"  "[ \"\$(bash \"$HERE/scripts/loop-policy.sh\" \"$S\")\" = suggest-wait ]"
rm -rf "$S" "$C"
[ "$fail" = 0 ] && echo "PASS: loop-policy" || { echo "loop-policy test failed"; exit 1; }
