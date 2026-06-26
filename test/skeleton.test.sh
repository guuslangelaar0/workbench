#!/usr/bin/env bash
# Verifies the workbench plugin skeleton is well-formed and registered.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"        # tools/workbench
MARKET="$HERE/../.claude-plugin/marketplace.json"             # tools/.claude-plugin/marketplace.json
fail=0
chk() { if eval "$2"; then echo "ok: $1"; else echo "FAIL: $1" >&2; fail=1; fi; }

chk "plugin.json exists"            "[ -f '$HERE/.claude-plugin/plugin.json' ]"
chk "plugin.json is valid JSON"     "python3 -m json.tool '$HERE/.claude-plugin/plugin.json' >/dev/null"
chk "plugin name is workbench"      "[ \"\$(python3 -c 'import json,sys;print(json.load(open(\"$HERE/.claude-plugin/plugin.json\"))[\"name\"])')\" = workbench ]"
chk "marketplace lists workbench"   "python3 -c 'import json;ps=json.load(open(\"$MARKET\"))[\"plugins\"];exit(0 if any(p[\"name\"]==\"workbench\" for p in ps) else 1)'"

[ "$fail" = 0 ] && echo "PASS: skeleton" || { echo "skeleton test failed"; exit 1; }
