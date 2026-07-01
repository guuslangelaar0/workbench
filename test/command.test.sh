#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # workbench
fail=0
chk() { if eval "$2"; then echo "ok: $1"; else echo "FAIL: $1" >&2; fail=1; fi; }

chk "init command exists"        "[ -f '$HERE/commands/init.md' ]"
chk "command has frontmatter"    "head -1 '$HERE/commands/init.md' | grep -q '^---'"
chk "command invokes init.sh"    "grep -q 'scripts/init.sh' '$HERE/commands/init.md'"
chk "command uses PLUGIN_ROOT"   "grep -q 'CLAUDE_PLUGIN_ROOT' '$HERE/commands/init.md'"

chk "boot command exists"       "[ -f '$HERE/commands/boot.md' ]"
chk "boot has reality phase"    "grep -qi 'reality\|verify' '$HERE/commands/boot.md'"
chk "checkpoint command exists" "[ -f '$HERE/commands/checkpoint.md' ]"
chk "checkpoint writes STATE"   "grep -q 'SESSION_STATE' '$HERE/commands/checkpoint.md'"

chk "lead command exists"       "[ -f '$HERE/commands/lead.md' ]"
chk "lead command uses lead.sh"  "grep -q 'scripts/lead.sh' '$HERE/commands/lead.md'"
chk "park command exists"       "[ -f '$HERE/commands/park.md' ]"
chk "park command uses park.sh"  "grep -q 'scripts/park.sh' '$HERE/commands/park.md'"
chk "mesh command exists"       "[ -f '$HERE/commands/mesh.md' ]"
chk "mesh command uses mesh.sh"  "grep -q 'scripts/mesh.sh' '$HERE/commands/mesh.md'"
chk "mesh command blocks public exposure" "grep -qi 'Never expose public internet' '$HERE/commands/mesh.md'"
chk "mesh command maps room chat intent" "grep -q 'message lead:checkout what are you touching' '$HERE/commands/mesh.md'"
chk "mesh command routes remote natural intent" "grep -q 'talk to my MacBook Claude' '$HERE/commands/mesh.md' && grep -q 'connect URL TOKEN' '$HERE/commands/mesh.md'"
chk "decision command exists" "[ -f '$HERE/commands/decision.md' ]"
chk "decision command creates decisions" "grep -q -- '--state decisions' '$HERE/commands/decision.md'"
chk "next command exists" "[ -f '$HERE/commands/next.md' ]"
chk "next command checks cap and blockers" "grep -qi 'in-review cap' '$HERE/commands/next.md' && grep -q 'Blocked-by' '$HERE/commands/next.md'"
chk "task command routes security bugs" "grep -qi 'security.*bug\\|passwords\\|secret' '$HERE/commands/task.md'"
chk "loop command routes cap and blockers" "grep -qi 'in-review cap' '$HERE/commands/loop.md' && grep -q 'Blocked-by' '$HERE/commands/loop.md'"
chk "epic command routes big efforts" "grep -qi 'multi-part effort\\|initiative' '$HERE/commands/epic.md'"
chk "codex-engineer command exists" "[ -f '$HERE/commands/codex-engineer.md' ]"
chk "codex-engineer command has frontmatter" "head -1 '$HERE/commands/codex-engineer.md' | grep -q '^---'"
chk "codex-engineer command uses Agent" "grep -q 'Agent' '$HERE/commands/codex-engineer.md'"
chk "codex-engineer command routes Codex natural intent" "grep -qi 'dispatch.*Codex\\|Codex.*engineer\\|give.*Codex' '$HERE/commands/codex-engineer.md'"

[ "$fail" = 0 ] && echo "PASS: command" || { echo "command test failed"; exit 1; }
