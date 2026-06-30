#!/usr/bin/env bash
# Runs init.sh into a temp dir and asserts the scaffold is correct.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # workbench
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail=0
chk() { if eval "$2"; then echo "ok: $1"; else echo "FAIL: $1" >&2; fail=1; fi; }

bash "$HERE/scripts/init.sh" --profile minimal --name "Acme" --mission "Privacy & speed." --launch "2027-01-01" --target "$TMP" >/dev/null 2>&1

chk "missing flag value exits 64"  "bash '$HERE/scripts/init.sh' --name >/dev/null 2>&1; [ \$? -eq 64 ]"
chk "unwritable target exits nonzero"  "bash '$HERE/scripts/init.sh' --name X --target /dev/null/x >/dev/null 2>&1; [ \$? -ne 0 ]"
chk "backlog dir created"        "[ -d '$TMP/.claude/tasks/backlog' ]"
chk "decisions dir created"      "[ -d '$TMP/.claude/tasks/decisions' ]"
chk "_next-id is 0001"           "[ \"\$(cat '$TMP/.claude/tasks/_next-id')\" = 0001 ]"
chk "task README copied"         "[ -f '$TMP/.claude/tasks/README.md' ]"
chk "CLAUDE.md rendered"         "[ -f '$TMP/CLAUDE.md' ]"
chk "CLAUDE has project name"    "grep -q 'Acme' '$TMP/CLAUDE.md'"
chk "no unrendered placeholder"  "! grep -q '{{' '$TMP/CLAUDE.md'"
chk "ampersand mission rendered literally"  "grep -qF 'Privacy & speed.' '$TMP/CLAUDE.md'"
chk "config is valid JSON"       "python3 -m json.tool '$TMP/.workbench/config.json' >/dev/null"
chk "config name == Acme"        "[ \"\$(python3 -c 'import json;print(json.load(open(\"$TMP/.workbench/config.json\"))[\"project\"][\"name\"])')\" = Acme ]"
chk "manifest is valid JSON"     "python3 -m json.tool '$TMP/.workbench/manifest.json' >/dev/null"
chk "scaffold gitignores mesh runtime" "grep -qxF '/.workbench/mesh/' '$TMP/.gitignore'"
bash "$HERE/scripts/init.sh" --profile minimal --name "Acme" --mission "Privacy & speed." --launch "2027-01-01" --target "$TMP" >/dev/null 2>&1
chk "mesh gitignore line not duplicated" "[ \"\$(grep -cxF '/.workbench/mesh/' '$TMP/.gitignore')\" = 1 ]"
chk "manifest hash matches file" "python3 - <<PY
import json,hashlib
m=json.load(open('$TMP/.workbench/manifest.json'))
h=hashlib.sha256(open('$TMP/CLAUDE.md','rb').read()).hexdigest()
rec=[f for f in m['files'] if f['path']=='CLAUDE.md'][0]
exit(0 if rec['rendered_hash']=='sha256:'+h else 1)
PY"

# --- re-running init.sh must NOT clobber existing managed files (greenfield-only scaffold) ---
TMP2="$(mktemp -d)"
bash "$HERE/scripts/init.sh" --profile full --name "Orig" --mission "m" --target "$TMP2" >/dev/null 2>&1
echo "USER-EDIT-CLAUDE"  >> "$TMP2/CLAUDE.md"
echo "USER-EDIT-AGENTS"  >> "$TMP2/AGENTS.md"
echo "USER-EDIT-SOUL"    >> "$TMP2/.claude/SOUL.md"
echo "USER-EDIT-README"  >> "$TMP2/.claude/tasks/README.md"
echo "# USER-EDIT-COORD" >> "$TMP2/scripts/coord/lib.sh"
re_out="$(bash "$HERE/scripts/init.sh" --profile full --name "Orig" --mission "m" --target "$TMP2" 2>&1)"
chk "re-run preserves CLAUDE.md edit"  "grep -q USER-EDIT-CLAUDE '$TMP2/CLAUDE.md'"
chk "re-run preserves AGENTS.md edit"  "grep -q USER-EDIT-AGENTS '$TMP2/AGENTS.md'"
chk "re-run preserves SOUL.md edit"    "grep -q USER-EDIT-SOUL '$TMP2/.claude/SOUL.md'"
chk "re-run preserves README edit"     "grep -q USER-EDIT-README '$TMP2/.claude/tasks/README.md'"
chk "re-run preserves coord edit"      "grep -q USER-EDIT-COORD '$TMP2/scripts/coord/lib.sh'"
chk "re-run reports preserved files"   "printf '%s' \"\$re_out\" | grep -qi preserved"
rm -rf "$TMP2"

TMPW="$(mktemp -d)"
bash "$HERE/scripts/init.sh" --profile full --name "Wb" --mission m --target "$TMPW" >/dev/null 2>&1
chk "scaffolds .workbench/ not .initlab/" "[ -f '$TMPW/.workbench/config.json' ] && [ ! -d '$TMPW/.initlab' ]"
chk "full scaffold gitignores mesh runtime" "grep -qxF '/.workbench/mesh/' '$TMPW/.gitignore'"
rm -rf "$TMPW"

[ "$fail" = 0 ] && echo "PASS: init" || { echo "init test failed"; exit 1; }
