#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail=0
chk() { if eval "$2"; then echo "ok: $1"; else echo "FAIL: $1" >&2; fail=1; fi; }

T1="$(mktemp -d)"; bash "$HERE/scripts/init.sh" --profile full --level solo  --name S --mission m --target "$T1" >/dev/null 2>&1
chk "solo: no in-review dir"   "[ ! -d '$T1/.claude/tasks/in-review' ]"
chk "solo: has verified dir"   "[ -d '$T1/.claude/tasks/verified' ]"
chk "solo: config level=solo"  "grep -q '\"level\": \"solo\"' '$T1/.workbench/config.json'"
chk "solo: no persisted dials block"  "! grep -q '\"dials\"' '$T1/.workbench/config.json'"
chk "solo: no persisted lifecycle.states" "! grep -q '\"states\"' '$T1/.workbench/config.json'"
chk "solo: config valid JSON"  "python3 -m json.tool '$T1/.workbench/config.json' >/dev/null"

T2="$(mktemp -d)"; bash "$HERE/scripts/init.sh" --profile full --level fleet --name F --mission m --target "$T2" >/dev/null 2>&1
chk "fleet: has release-candidate dir" "[ -d '$T2/.claude/tasks/release-candidate' ]"
chk "fleet: has staged dir"            "[ -d '$T2/.claude/tasks/staged' ]"
chk "fleet: config valid JSON"         "python3 -m json.tool '$T2/.workbench/config.json' >/dev/null"
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

# C2: re-stamp case — scaffold solo, add sentinel field, re-run --level crew
TRESTAMP="$(mktemp -d)"
bash "$HERE/scripts/init.sh" --profile full --level solo --name "RStamp" --mission m --target "$TRESTAMP" >/dev/null 2>&1
# Add a sentinel field to project using python3 (allowed in tests)
python3 - "$TRESTAMP/.workbench/config.json" <<'PY'
import json, sys
cfg = json.load(open(sys.argv[1]))
cfg["project"]["_sentinel"] = "preserve-me"
json.dump(cfg, open(sys.argv[1], 'w'), indent=2)
PY
bash "$HERE/scripts/init.sh" --name "RStamp" --level crew --target "$TRESTAMP" >/dev/null 2>&1
chk "restamp: level updated to crew"     "grep -q '\"level\": \"crew\"' '$TRESTAMP/.workbench/config.json'"
chk "restamp: staged dir created"        "[ -d '$TRESTAMP/.claude/tasks/staged' ]"
chk "restamp: sentinel preserved"        "python3 -c \"import json; c=json.load(open('$TRESTAMP/.workbench/config.json')); exit(0 if c['project'].get('_sentinel')=='preserve-me' else 1)\""
chk "restamp: valid JSON after restamp"  "python3 -m json.tool '$TRESTAMP/.workbench/config.json' >/dev/null"
rm -rf "$TRESTAMP"

# C3: wizard-path — minimal config with no level, run --level pair, assert level inserted + project.name preserved + valid JSON
TWIZ="$(mktemp -d)"
mkdir -p "$TWIZ/.workbench"
printf '{"workbench":{"version":"0.1.0","initialized_at":"2026-01-01T00:00:00Z"},"project":{"name":"W","kind":"existing"},"way_of_working":{"models":"recommended","verification":"recommended","review":"recommended","parallelism":"recommended","enforcement":"warn-default","continuity":"recommended","graphify":"off","codex":"off","remote":"off","inception_depth":"recommended"},"lifecycle":{"in_review_cap":10}}' > "$TWIZ/.workbench/config.json"
bash "$HERE/scripts/init.sh" --name "W" --level pair --target "$TWIZ" >/dev/null 2>&1
chk "wizard: level pair inserted"        "grep -q '\"level\": \"pair\"' '$TWIZ/.workbench/config.json'"
chk "wizard: project.name W preserved"  "python3 -c \"import json; c=json.load(open('$TWIZ/.workbench/config.json')); exit(0 if c['project']['name']=='W' else 1)\""
chk "wizard: valid JSON after wizard"   "python3 -m json.tool '$TWIZ/.workbench/config.json' >/dev/null"
rm -rf "$TWIZ"

# C4: rich-config — config with project.repos array + prod object + way_of_working, re-run --level fleet
TRICH="$(mktemp -d)"
bash "$HERE/scripts/init.sh" --profile full --level solo --name "Rich" --mission m --target "$TRICH" >/dev/null 2>&1
# Inject a repos array + prod object using python3
python3 - "$TRICH/.workbench/config.json" <<'PY'
import json, sys
cfg = json.load(open(sys.argv[1]))
cfg["project"]["repos"] = ["repo-a", "repo-b", "repo-c"]
cfg["project"]["prod"] = {"api": "https://api.example.com", "web": "https://example.com"}
json.dump(cfg, open(sys.argv[1], 'w'), indent=2)
PY
bash "$HERE/scripts/init.sh" --name "Rich" --level fleet --target "$TRICH" >/dev/null 2>&1
chk "rich: level fleet set"           "grep -q '\"level\": \"fleet\"' '$TRICH/.workbench/config.json'"
chk "rich: valid JSON after fleet"    "python3 -m json.tool '$TRICH/.workbench/config.json' >/dev/null"
chk "rich: repos array length preserved" "python3 -c \"import json; c=json.load(open('$TRICH/.workbench/config.json')); exit(0 if len(c['project']['repos'])==3 else 1)\""
chk "rich: release-candidate dir exists" "[ -d '$TRICH/.claude/tasks/release-candidate' ]"
rm -rf "$TRICH"

[ "$fail" = 0 ] && echo "PASS: lifecycle" || { echo "lifecycle test failed"; exit 1; }
