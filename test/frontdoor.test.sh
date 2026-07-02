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
chk "front door names hook recommendation" "grep -qi 'hook' '$F' && grep -qi 'recommended' '$F'"
chk "front door describes skip hooks lower benefit" "grep -qi 'skip hooks\\|without hooks\\|lower benefit\\|less benefit' '$F'"
chk "setup command refers to front door" "grep -q '/workbench:workbench' '$HERE/commands/setup.md'"
chk "init command refers to front door" "grep -q '/workbench:workbench' '$HERE/commands/init.md'"
chk "setup skill asks hook choice" "grep -qi 'Install Workbench hooks' '$HERE/skills/setup/SKILL.md'"
chk "setup skill explains skip hooks" "grep -qi 'slash commands still work' '$HERE/skills/setup/SKILL.md'"
[ "$fail" = 0 ] && echo "PASS: frontdoor" || { echo "frontdoor test failed"; exit 1; }
