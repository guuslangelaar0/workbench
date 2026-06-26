#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fail=0
chk() { if eval "$2"; then echo "ok: $1"; else echo "FAIL: $1" >&2; fail=1; fi; }
jmode() { python3 -c "import json,sys;d=json.load(open(sys.argv[1]));print(next((f['mode'] for f in d['files'] if f['path']==sys.argv[2]),'MISSING'))" "$1" "$2"; }

bash "$HERE/scripts/init.sh" --name "Acme" --mission "Private." --target "$TMP" >/dev/null 2>&1
chk "SESSION_STATE rendered"      "[ -f '$TMP/.claude/SESSION_STATE.md' ]"
chk "SESSION_STATE has name"      "grep -q 'Acme' '$TMP/.claude/SESSION_STATE.md'"
chk "SESSION_STATE no tokens"     "! grep -q '{{' '$TMP/.claude/SESSION_STATE.md'"
chk "manifest SESSION_STATE once" "[ \"\$(jmode '$TMP/.workbench/manifest.json' '.claude/SESSION_STATE.md')\" = once ]"
# once: a re-run must not clobber edits
echo "EDITED-BY-USER" >> "$TMP/.claude/SESSION_STATE.md"
bash "$HERE/scripts/init.sh" --name "Acme" --mission "Private." --target "$TMP" >/dev/null 2>&1
chk "SESSION_STATE preserved"     "grep -q 'EDITED-BY-USER' '$TMP/.claude/SESSION_STATE.md'"

# the grounding hook prints a useful brief for an initlab project, and no-ops elsewhere
BRIEF="$(CLAUDE_PROJECT_DIR="$TMP" bash "$HERE/hooks/bin/ground-session.sh" </dev/null 2>/dev/null)"
chk "brief mentions project"   "printf '%s' \"\$BRIEF\" | grep -q 'Acme'"
chk "brief shows task counts"  "printf '%s' \"\$BRIEF\" | grep -qi 'backlog'"
chk "brief points to SOUL"     "printf '%s' \"\$BRIEF\" | grep -q 'SOUL.md'"
NOOP="$(CLAUDE_PROJECT_DIR="$(mktemp -d)" bash "$HERE/hooks/bin/ground-session.sh" </dev/null 2>/dev/null; echo "rc=$?")"
chk "no-op in non-initlab dir"  "[ \"\$NOOP\" = 'rc=0' ]"

[ "$fail" = 0 ] && echo "PASS: continuity" || { echo "continuity test failed"; exit 1; }
