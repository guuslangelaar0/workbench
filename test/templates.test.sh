#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # workbench
T="$HERE/templates"
fail=0
chk() { if eval "$2"; then echo "ok: $1"; else echo "FAIL: $1" >&2; fail=1; fi; }

chk "CLAUDE template exists"     "[ -f '$T/minimal/CLAUDE.md.tmpl' ]"
chk "CLAUDE has PROJECT_NAME ph" "grep -q '{{PROJECT_NAME}}' '$T/minimal/CLAUDE.md.tmpl'"
chk "CLAUDE has MISSION ph"      "grep -q '{{MISSION}}' '$T/minimal/CLAUDE.md.tmpl'"
chk "CLAUDE has LAUNCH ph"       "grep -q '{{LAUNCH}}' '$T/minimal/CLAUDE.md.tmpl'"
chk "minimal CLAUDE has release notes contract" "grep -q 'Release notes contract' '$T/minimal/CLAUDE.md.tmpl' && grep -q 'vX.Y.Z — short release name' '$T/minimal/CLAUDE.md.tmpl'"
chk "full CLAUDE has release notes contract" "grep -q 'Release notes contract' '$T/full/CLAUDE.md.tmpl' && grep -q 'Bug Fixes / Hardening' '$T/full/CLAUDE.md.tmpl'"
chk "minimal CLAUDE routes decisions and blockers" "grep -q '/workbench:decision' '$T/minimal/CLAUDE.md.tmpl' && grep -q 'Blocked-by' '$T/minimal/CLAUDE.md.tmpl'"
chk "full CLAUDE routes decisions and blockers" "grep -q '/workbench:decision' '$T/full/CLAUDE.md.tmpl' && grep -q 'Blocked-by' '$T/full/CLAUDE.md.tmpl'"
chk "AGENTS has release notes contract" "grep -q 'Release notes contract' '$T/full/AGENTS.md.tmpl' && grep -q 'vX.Y.Z — short release name' '$T/full/AGENTS.md.tmpl'"
chk "task README exists"         "[ -f '$T/minimal/tasks/README.md' ]"
chk "_next-id is 0001"           "[ \"\$(cat '$T/minimal/tasks/_next-id')\" = 0001 ]"
chk "config schema valid JSON"   "python3 -m json.tool '$T/schemas/config.schema.json' >/dev/null"
chk "manifest schema valid JSON" "python3 -m json.tool '$T/schemas/manifest.schema.json' >/dev/null"

[ "$fail" = 0 ] && echo "PASS: templates" || { echo "templates test failed"; exit 1; }
