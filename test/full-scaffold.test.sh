#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fail=0
chk() { if eval "$2"; then echo "ok: $1"; else echo "FAIL: $1" >&2; fail=1; fi; }
jmode() { python3 -c "import json,sys;d=json.load(open(sys.argv[1]));print(next(f['mode'] for f in d['files'] if f['path']==sys.argv[2]))" "$1" "$2"; }

bash "$HERE/scripts/init.sh" --name "Acme" --mission "Private & fast." --target "$TMP" >/dev/null 2>&1

chk "SOUL.md rendered"        "[ -f '$TMP/.claude/SOUL.md' ]"
chk "SOUL has project name"   "grep -q 'Acme' '$TMP/.claude/SOUL.md'"
chk "AGENTS.md rendered"      "[ -f '$TMP/AGENTS.md' ]"
chk "full CLAUDE rendered"    "grep -q 'How work flows' '$TMP/CLAUDE.md'"
chk "no leftover tokens"      "! grep -rq '{{' '$TMP/CLAUDE.md' '$TMP/.claude/SOUL.md' '$TMP/AGENTS.md'"
chk "coord scripts copied"    "[ -f '$TMP/scripts/coord/wb-coord' ] && [ -f '$TMP/scripts/coord/lib.sh' ]"
chk "manifest has SOUL merge" "[ \"\$(jmode '$TMP/.workbench/manifest.json' '.claude/SOUL.md')\" = merge ]"
chk "manifest coord managed"  "[ \"\$(jmode '$TMP/.workbench/manifest.json' 'scripts/coord/wb-coord')\" = managed ]"
chk "manifest _next-id once"  "[ \"\$(jmode '$TMP/.workbench/manifest.json' '.claude/tasks/_next-id')\" = once ]"
echo "0042" > "$TMP/.claude/tasks/_next-id"
bash "$HERE/scripts/init.sh" --name "Acme" --mission "x" --target "$TMP" >/dev/null 2>&1
chk "re-run preserves _next-id" "[ \"\$(cat '$TMP/.claude/tasks/_next-id')\" = 0042 ]"

# git pre-commit guard actually installs into a real git repo
G="$(mktemp -d)"; ( cd "$G" && git init -q )
bash "$HERE/scripts/init.sh" --name "HookTest" --mission "x" --target "$G" >/dev/null 2>&1
chk "pre-commit guard installed" "[ -f '$G/.git/hooks/pre-commit' ] && grep -q 'wb-coord commit guard' '$G/.git/hooks/pre-commit'"
rm -rf "$G"

[ "$fail" = 0 ] && echo "PASS: full-scaffold" || { echo "full-scaffold test failed"; exit 1; }
