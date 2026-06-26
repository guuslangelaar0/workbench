#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$HERE/templates/full"
fail=0
chk() { if eval "$2"; then echo "ok: $1"; else echo "FAIL: $1" >&2; fail=1; fi; }

chk "SOUL template exists"        "[ -f '$T/SOUL.md.tmpl' ]"
chk "SOUL has PROJECT_NAME token" "grep -q '{{PROJECT_NAME}}' '$T/SOUL.md.tmpl'"
chk "SOUL keeps failure modes"    "grep -qi 'park.*human\|overclaim' '$T/SOUL.md.tmpl'"
chk "SOUL keeps default-continue" "grep -qi 'default is CONTINUE\|default.*continue' '$T/SOUL.md.tmpl'"
chk "SOUL has no beebeeb refs"    "! grep -qi 'beebeeb\|falkenstein\|hetzner\|opaque' '$T/SOUL.md.tmpl'"

chk "CLAUDE-full template exists" "[ -f '$T/CLAUDE.md.tmpl' ]"
chk "CLAUDE-full has tokens"      "grep -q '{{PROJECT_NAME}}' '$T/CLAUDE.md.tmpl' && grep -q '{{MISSION}}' '$T/CLAUDE.md.tmpl'"
chk "CLAUDE-full points to SOUL"  "grep -q 'SOUL.md' '$T/CLAUDE.md.tmpl'"
chk "AGENTS template exists"      "[ -f '$T/AGENTS.md.tmpl' ]"
chk "AGENTS points to CLAUDE"     "grep -q 'CLAUDE.md' '$T/AGENTS.md.tmpl'"

[ "$fail" = 0 ] && echo "PASS: soul" || { echo "soul test failed"; exit 1; }
