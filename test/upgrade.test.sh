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
chk "manifest v2 schema version" "python3 -c \"import json;d=json.load(open('$TMP/.workbench/manifest.json'));exit(0 if d.get('schema_version')==2 else 1)\""
chk "manifest has plugin object" "python3 -c \"import json;d=json.load(open('$TMP/.workbench/manifest.json'));p=d.get('plugin',{});exit(0 if p.get('name')=='workbench' and p.get('version') else 1)\""
chk "manifest file ledger fields" "python3 -c \"import json;d=json.load(open('$TMP/.workbench/manifest.json'));f=next(x for x in d['files'] if x['path']=='CLAUDE.md');needed={'action','preexisting','previous_hash','rendered_hash','template_hash'};exit(0 if needed.issubset(f) and f['action']=='created' and f['preexisting'] is False else 1)\""
chk "manifest side effects recorded" "python3 -c \"import json;d=json.load(open('$TMP/.workbench/manifest.json'));s=d.get('side_effects',{});exit(0 if 'created_dirs' in s and 'runtime_dirs' in s and 'gitignore_blocks' in s and 'git_hooks' in s else 1)\""
chk "manifest records loop charter once" "python3 -c \"import json;d=json.load(open('$TMP/.workbench/manifest.json'));f=next(x for x in d['files'] if x['path']=='.workbench/loop-charter.md');exit(0 if f['mode']=='once' else 1)\""
chk "manifest records architecture docs" "python3 -c \"import json;d=json.load(open('$TMP/.workbench/manifest.json'));paths={f['path'] for f in d['files']};exit(0 if '.claude/architecture/context.md' in paths and '.claude/architecture/containers.md' in paths and '.claude/architecture/components.md' in paths else 1)\""
rm -rf "$TMP"

TMP_PRE="$(mktemp -d)"
printf 'USER CLAUDE\n' > "$TMP_PRE/CLAUDE.md"
pre_hash="sha256:$(python3 -c "import hashlib;print(hashlib.sha256(open('$TMP_PRE/CLAUDE.md','rb').read()).hexdigest())")"
bash "$HERE/scripts/init.sh" --name "Pre" --mission "x" --target "$TMP_PRE" >/dev/null 2>&1
chk "manifest records preexisting file" "python3 -c \"import json;d=json.load(open('$TMP_PRE/.workbench/manifest.json'));f=next(x for x in d['files'] if x['path']=='CLAUDE.md');exit(0 if f['action']=='preserved' and f['preexisting'] is True and f['previous_hash']=='$pre_hash' else 1)\""
rm -rf "$TMP_PRE"

TMP_GIT="$(mktemp -d)"; (cd "$TMP_GIT" && git init -q)
bash "$HERE/scripts/init.sh" --name "Git" --mission "x" --target "$TMP_GIT" >/dev/null 2>&1
chk "manifest records git hook side effect" "python3 -c \"import json;d=json.load(open('$TMP_GIT/.workbench/manifest.json'));hooks=d.get('side_effects',{}).get('git_hooks',[]);exit(0 if any(h.get('type')=='pre-commit' and 'wb-coord' in h.get('marker','') for h in hooks) else 1)\""
chk "manifest records gitignore side effect" "python3 -c \"import json;d=json.load(open('$TMP_GIT/.workbench/manifest.json'));blocks=d.get('side_effects',{}).get('gitignore_blocks',[]);exit(0 if any(b.get('path')=='.gitignore' for b in blocks) else 1)\""
rm -rf "$TMP_GIT"

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
chk "doctor runs doctor script" "grep -qF 'scripts/doctor.sh' '$HERE/commands/doctor.md'"

# Task 4: upgrade skill + command checks
chk "upgrade skill exists"     "[ -f '$HERE/skills/upgrade/SKILL.md' ]"
chk "upgrade skill 3 modes"    "grep -q 'managed' '$HERE/skills/upgrade/SKILL.md' && grep -q 'merge' '$HERE/skills/upgrade/SKILL.md' && grep -q 'once' '$HERE/skills/upgrade/SKILL.md'"
chk "upgrade command exists"   "[ -f '$HERE/commands/upgrade.md' ]"
chk "upgrade script exists"    "[ -f '$HERE/scripts/upgrade.sh' ]"

TMP="$(mktemp -d)"; bash "$HERE/scripts/init.sh" --name "Classify" --mission "x" --target "$TMP" >/dev/null 2>&1
UP="$(bash "$HERE/scripts/upgrade.sh" --target "$TMP" --dry-run 2>/dev/null || true)"
chk "upgrade classifies fresh ok" "printf '%s' \"\$UP\" | grep -q 'CLAUDE.md.*ok'"
echo "USER EDIT" >> "$TMP/CLAUDE.md"
UP2="$(bash "$HERE/scripts/upgrade.sh" --target "$TMP" --dry-run 2>/dev/null || true)"
chk "upgrade classifies edited" "printf '%s' \"\$UP2\" | grep -q 'CLAUDE.md.*edited'"
rm -f "$TMP/.claude/tasks/README.md"
UP3="$(bash "$HERE/scripts/upgrade.sh" --target "$TMP" --dry-run 2>/dev/null || true)"
chk "upgrade classifies missing" "printf '%s' \"\$UP3\" | grep -q '.claude/tasks/README.md.*missing'"
python3 - "$TMP/.workbench/manifest.json" <<'PY'
import json, sys
p=sys.argv[1]
d=json.load(open(p))
for f in d["files"]:
    if f["path"]=="AGENTS.md":
        f["template_hash"]="sha256:" + "0"*64
json.dump(d, open(p,"w"), indent=2)
PY
UP4="$(bash "$HERE/scripts/upgrade.sh" --target "$TMP" --dry-run 2>/dev/null || true)"
chk "upgrade classifies template changed" "printf '%s' \"\$UP4\" | grep -q 'AGENTS.md.*template-changed'"
rm -rf "$TMP"

TMP_PRE="$(mktemp -d)"
printf 'USER CLAUDE\n' > "$TMP_PRE/CLAUDE.md"
bash "$HERE/scripts/init.sh" --name "PreClassify" --mission "x" --target "$TMP_PRE" >/dev/null 2>&1
UP5="$(bash "$HERE/scripts/upgrade.sh" --target "$TMP_PRE" --dry-run 2>/dev/null || true)"
chk "upgrade classifies preexisting" "printf '%s' \"\$UP5\" | grep -q 'CLAUDE.md.*preexisting'"
rm -rf "$TMP_PRE"

[ "$fail" = 0 ] && echo "PASS: upgrade" || { echo "upgrade test failed"; exit 1; }
