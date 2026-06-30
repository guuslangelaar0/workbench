#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail=0
chk() { if eval "$2"; then echo "ok: $1"; else echo "FAIL: $1" >&2; fail=1; fi; }

chk "bin launcher exists" "[ -f '$HERE/bin/workbench-mesh' ]"
chk "bin launcher executable" "[ -x '$HERE/bin/workbench-mesh' ]"
chk "scripts mesh wrapper exists" "[ -f '$HERE/scripts/mesh.sh' ]"
chk "mesh wrapper syntactically valid" "bash -n '$HERE/scripts/mesh.sh'"
chk "mesh command exists" "[ -f '$HERE/commands/mesh.md' ]"
chk "mesh command calls mesh.sh" "grep -q 'scripts/mesh.sh' '$HERE/commands/mesh.md'"
chk "mesh skill exists" "[ -f '$HERE/skills/mesh/SKILL.md' ]"
chk "validate plugin knows bin surface" "bash '$HERE/scripts/validate-plugin.sh' '$HERE' | grep -q 'publishable'"

[ "$fail" = 0 ] && echo "PASS: mesh-packaging" || { echo "mesh-packaging test failed"; exit 1; }
