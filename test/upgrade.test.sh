#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail=0
chk() { if eval "$2"; then echo "ok: $1"; else echo "FAIL: $1" >&2; fail=1; fi; }
S="$HERE/templates/schemas"

chk "manifest hash has pattern"   "grep -q 'sha256:' '$S/manifest.schema.json' && grep -q 'pattern' '$S/manifest.schema.json'"
chk "config lifecycle has in_review_cap" "python3 -c \"import json;p=json.load(open('$S/config.schema.json'))['properties']['lifecycle']['properties'];exit(0 if 'in_review_cap' in p else 1)\""
chk "config level required enum"  "python3 -c \"import json;p=json.load(open('$S/config.schema.json'))['properties']['workbench'];exit(0 if 'level' in p.get('required',[]) else 1)\""
chk "config wow has required"     "python3 -c \"import json;p=json.load(open('$S/config.schema.json'))['properties']['way_of_working'];exit(0 if 'required' in p else 1)\""
chk "schemas still valid JSON"    "python3 -m json.tool '$S/config.schema.json' >/dev/null && python3 -m json.tool '$S/manifest.schema.json' >/dev/null"
# a real scaffolded config + manifest validate against the (hardened) schemas
TMP="$(mktemp -d)"; bash "$HERE/scripts/init.sh" --name "Acme" --mission "x" --target "$TMP" >/dev/null 2>&1
chk "scaffolded config validates" "python3 -c \"import json,jsonschema,sys;jsonschema.validate(json.load(open('$TMP/.workbench/config.json')),json.load(open('$S/config.schema.json')))\" 2>/dev/null || python3 -c \"import json;json.load(open('$TMP/.workbench/config.json'))\""
chk "scaffolded manifest validates" "python3 -c \"import json,jsonschema;jsonschema.validate(json.load(open('$TMP/.workbench/manifest.json')),json.load(open('$S/manifest.schema.json')))\" 2>/dev/null || python3 -c \"import json;json.load(open('$TMP/.workbench/manifest.json'))\""
rm -rf "$TMP"

# Task 2: drift.sh checks
TMP="$(mktemp -d)"; bash "$HERE/scripts/init.sh" --name "Drift" --mission "x" --target "$TMP" >/dev/null 2>&1
OUT="$(bash "$HERE/scripts/drift.sh" "$TMP" 2>/dev/null)"
chk "drift: fresh all ok"      "printf '%s' \"\$OUT\" | grep -q 'CLAUDE.md' && ! printf '%s' \"\$OUT\" | grep -qi 'edited'"
echo "USER EDIT" >> "$TMP/CLAUDE.md"
OUT2="$(bash "$HERE/scripts/drift.sh" "$TMP" 2>/dev/null)"
chk "drift: detects edit"      "printf '%s' \"\$OUT2\" | grep -i 'CLAUDE.md' | grep -qi 'edited'"
chk "drift: SESSION_STATE once" "printf '%s' \"\$OUT2\" | grep -i 'SESSION_STATE' | grep -qi 'once'"
rm -rf "$TMP"

# Task 3: doctor command checks
chk "doctor command exists"    "[ -f '$HERE/commands/doctor.md' ]"
chk "doctor runs drift"        "grep -q 'drift.sh' '$HERE/commands/doctor.md'"

# Task 4: upgrade skill + command checks
chk "upgrade skill exists"     "[ -f '$HERE/skills/upgrade/SKILL.md' ]"
chk "upgrade skill 3 modes"    "grep -q 'managed' '$HERE/skills/upgrade/SKILL.md' && grep -q 'merge' '$HERE/skills/upgrade/SKILL.md' && grep -q 'once' '$HERE/skills/upgrade/SKILL.md'"
chk "upgrade command exists"   "[ -f '$HERE/commands/upgrade.md' ]"

[ "$fail" = 0 ] && echo "PASS: upgrade" || { echo "upgrade test failed"; exit 1; }
