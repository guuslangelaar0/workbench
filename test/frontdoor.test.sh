#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail=0
chk() { if eval "$2"; then echo "ok: $1"; else echo "FAIL: $1" >&2; fail=1; fi; }
F="$HERE/commands/workbench.md"
chk "front door command exists"        "[ -f '$F' ]"
chk "front door: unconfigured -> wizard" "grep -qi 'config.json' '$F' && grep -qi 'adoption\|wizard\|assess' '$F'"
chk "front door: configured -> status"   "grep -qi 'status\|next action' '$F'"
chk "front door: positive feedback"      "grep -qi 'positive' '$F'"
chk "setup skill assesses + recommends level" "grep -qi 'level' '$HERE/skills/setup/SKILL.md' && grep -qi 'assess\|positive' '$HERE/skills/setup/SKILL.md'"
[ "$fail" = 0 ] && echo "PASS: frontdoor" || { echo "frontdoor test failed"; exit 1; }
