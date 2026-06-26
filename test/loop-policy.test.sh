#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail=0
chk() { if eval "$2"; then echo "ok: $1"; else echo "FAIL: $1" >&2; fail=1; fi; }

S="$(mktemp -d)"; bash "$HERE/scripts/init.sh" --profile full --level solo  --name S --mission m --target "$S" >/dev/null 2>&1
C="$(mktemp -d)"; bash "$HERE/scripts/init.sh" --profile full --level crew  --name C --mission m --target "$C" >/dev/null 2>&1
chk "solo -> auto-continue" "[ \"\$(bash \"$HERE/scripts/loop-policy.sh\" \"$S\")\" = auto-continue ]"
chk "crew -> suggest-wait"  "[ \"\$(bash \"$HERE/scripts/loop-policy.sh\" \"$C\")\" = suggest-wait ]"

# dial_overrides.loop_autonomy beats the level preset
# Inject override using python3 to keep the config valid JSON
python3 - "$S/.workbench/config.json" <<'PY'
import json, sys
cfg = json.load(open(sys.argv[1]))
if "dial_overrides" not in cfg:
    cfg["dial_overrides"] = {}
cfg["dial_overrides"]["loop_autonomy"] = "suggest-wait"
json.dump(cfg, open(sys.argv[1], 'w'), indent=2)
PY
chk "dial_overrides beats preset"  "[ \"\$(bash \"$HERE/scripts/loop-policy.sh\" \"$S\")\" = suggest-wait ]"
chk "config still valid JSON after override" "python3 -m json.tool '$S/.workbench/config.json' >/dev/null"

rm -rf "$S" "$C"
[ "$fail" = 0 ] && echo "PASS: loop-policy" || { echo "loop-policy test failed"; exit 1; }
