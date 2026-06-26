#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fail=0
chk() { if eval "$2"; then echo "ok: $1"; else echo "FAIL: $1" >&2; fail=1; fi; }

# A pre-written config (as the wizard would write) must NOT be overwritten by init.sh
mkdir -p "$TMP/.workbench"
printf '{ "workbench": { "version": "0.0.0", "initialized_at": "x" }, "project": { "name": "Prewritten", "kind": "existing" }, "way_of_working": { "models": "better" }, "lifecycle": { "states": ["backlog"], "in_review_cap": 7 } }' > "$TMP/.workbench/config.json"
bash "$HERE/scripts/init.sh" --name "Override" --mission "x" --target "$TMP" >/dev/null 2>&1
chk "existing config preserved" "[ \"\$(python3 -c 'import json;print(json.load(open(\"$TMP/.workbench/config.json\"))[\"project\"][\"name\"])')\" = Prewritten ]"
chk "preserved models=better"   "[ \"\$(python3 -c 'import json;print(json.load(open(\"$TMP/.workbench/config.json\"))[\"way_of_working\"][\"models\"])')\" = better ]"
chk "scaffold still happened"   "[ -f '$TMP/CLAUDE.md' ] && [ -d '$TMP/.claude/tasks/backlog' ]"

# but a fresh dir with no config still gets the default config written
TMP2="$(mktemp -d)"
bash "$HERE/scripts/init.sh" --name "Fresh" --mission "x" --target "$TMP2" >/dev/null 2>&1
chk "fresh config written"      "[ -f '$TMP2/.workbench/config.json' ] && grep -q Fresh '$TMP2/.workbench/config.json'"
rm -rf "$TMP2"

# setup skill + commands exist (filled in by later tasks; assert now so the suite tracks them)
chk "setup skill exists"        "[ -f '$HERE/skills/setup/SKILL.md' ]"
chk "setup command exists"      "[ -f '$HERE/commands/setup.md' ]"
chk "bare workbench command"    "[ -f '$HERE/commands/workbench.md' ]"

[ "$fail" = 0 ] && echo "PASS: setup" || { echo "setup test failed"; exit 1; }
