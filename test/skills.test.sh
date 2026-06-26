#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail=0
chk() { if eval "$2"; then echo "ok: $1"; else echo "FAIL: $1" >&2; fail=1; fi; }
S="$HERE/skills/session-continuity/SKILL.md"
chk "skill exists"            "[ -f '$S' ]"
chk "skill has frontmatter"   "head -1 '$S' | grep -q '^---'"
chk "skill has name+desc"     "grep -q '^name:' '$S' && grep -q '^description:' '$S'"
chk "skill covers checkpoint" "grep -qi 'checkpoint\|SESSION_STATE' '$S'"
chk "skill covers restart"    "grep -qi 'restart\|hygiene\|drift' '$S'"
[ "$fail" = 0 ] && echo "PASS: skills" || { echo "skills test failed"; exit 1; }
