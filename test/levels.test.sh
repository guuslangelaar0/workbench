#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$HERE/scripts/lib.sh"
. "$HERE/scripts/levels.sh"
fail=0
chk() { if eval "$2"; then echo "ok: $1"; else echo "FAIL: $1" >&2; fail=1; fi; }

chk "lists four levels"            "[ \"\$(wb_levels)\" = 'solo pair crew fleet' ]"
chk "solo lifecycle has no in-review" "! wb_level_lifecycle solo | grep -qw in-review"
chk "pair lifecycle adds in-review"   "wb_level_lifecycle pair | grep -qw in-review"
chk "crew lifecycle adds staged"      "wb_level_lifecycle crew | grep -qw staged"
chk "fleet lifecycle adds release-candidate" "wb_level_lifecycle fleet | grep -qw release-candidate"
chk "decisions always present"        "wb_level_lifecycle solo | grep -qw decisions"
chk "solo loop_autonomy auto-continue" "wb_level_dials solo | grep -qx 'loop_autonomy=auto-continue'"
chk "crew loop_autonomy suggest-wait"  "wb_level_dials crew | grep -qx 'loop_autonomy=suggest-wait'"
chk "solo release push-to-main"        "wb_level_dials solo | grep -qx 'release=push-to-main'"
chk "fleet graphify federated"         "wb_level_dials fleet | grep -qx 'graphify=federated'"
chk "index orders levels"             "[ \"\$(wb_level_index fleet)\" -gt \"\$(wb_level_index solo)\" ]"
chk "unknown level returns 1"         "! wb_level_index bogus >/dev/null 2>&1"

chk "level command exists"              "[ -f '$HERE/commands/level.md' ]"
chk "level command: status/up/down"     "grep -qi 'status' '$HERE/commands/level.md' && grep -qi 'up' '$HERE/commands/level.md' && grep -qi 'down' '$HERE/commands/level.md'"
chk "level command: shows dial changes before applying" "grep -qi 'which dials\|dials change\|before applying\|confirm' '$HERE/commands/level.md'"
chk "levels skill exists"               "[ -f '$HERE/skills/levels/SKILL.md' ]"
chk "level command: no jq usage"        "! grep -q 'jq ' '$HERE/commands/level.md'"

# wb_dial: preset resolution
TPRESET="$(mktemp -d)"
bash "$HERE/scripts/init.sh" --profile full --level solo --name "DialTest" --mission m --target "$TPRESET" >/dev/null 2>&1
chk "wb_dial: solo loop_autonomy preset" "[ \"\$(wb_dial '$TPRESET' loop_autonomy)\" = auto-continue ]"
chk "wb_dial: solo release preset"       "[ \"\$(wb_dial '$TPRESET' release)\" = push-to-main ]"

# wb_dial: override beats preset
python3 - "$TPRESET/.workbench/config.json" <<'PY'
import json, sys
cfg = json.load(open(sys.argv[1]))
if "dial_overrides" not in cfg:
    cfg["dial_overrides"] = {}
cfg["dial_overrides"]["loop_autonomy"] = "suggest-wait"
json.dump(cfg, open(sys.argv[1], 'w'), indent=2)
PY
chk "wb_dial: override beats preset"   "[ \"\$(wb_dial '$TPRESET' loop_autonomy)\" = suggest-wait ]"
chk "wb_dial: non-overridden dial still uses preset" "[ \"\$(wb_dial '$TPRESET' release)\" = push-to-main ]"
chk "wb_dial: config still valid JSON" "python3 -m json.tool '$TPRESET/.workbench/config.json' >/dev/null"
rm -rf "$TPRESET"

[ "$fail" = 0 ] && echo "PASS: levels" || { echo "levels test failed"; exit 1; }
