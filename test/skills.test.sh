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
LP="$HERE/skills/lead-purpose/SKILL.md"
chk "lead-purpose skill exists"          "[ -f '$LP' ]"
chk "lead-purpose skill has frontmatter" "head -1 '$LP' | grep -q '^---'"
chk "lead-purpose covers parking"        "grep -qi 'park' '$LP'"
chk "lead-purpose covers purpose"        "grep -qi 'purpose' '$LP'"
MESH="$HERE/skills/mesh/SKILL.md"
chk "mesh skill exists"                  "[ -f '$MESH' ]"
chk "mesh skill has frontmatter"         "head -1 '$MESH' | grep -q '^---'"
chk "mesh skill maps outcomes"           "grep -qi 'outcomes' '$MESH' && grep -q '/workbench:mesh' '$MESH'"
chk "mesh skill covers chat/status/help" "grep -qi 'Chat, status, and help' '$MESH'"
chk "mesh skill blocks public exposure"  "grep -qi 'Public internet exposure is unavailable' '$MESH'"
[ "$fail" = 0 ] && echo "PASS: skills" || { echo "skills test failed"; exit 1; }
