#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fail=0
chk() { if eval "$2"; then echo "ok: $1"; else echo "FAIL: $1" >&2; fail=1; fi; }

chk "codex coord template"     "[ -f '$HERE/templates/codex/CODEX_COORDINATION.md.tmpl' ]"
chk "codex teamlead template"  "[ -f '$HERE/templates/codex/codex-teamlead-prompt.md.tmpl' ]"
chk "coord no beebeeb refs"    "! grep -qi 'beebeeb\|falkenstein\|hetzner' '$HERE/templates/codex/CODEX_COORDINATION.md.tmpl'"
chk "codex-bridge skill"       "[ -f '$HERE/skills/codex-bridge/SKILL.md' ]"
chk "skill refs codex:rescue"  "grep -q 'codex:rescue' '$HERE/skills/codex-bridge/SKILL.md'"
chk "codex engineer command exists" "[ -f '$HERE/commands/codex-engineer.md' ]"
chk "codex engineer command uses native subagent" "grep -q 'subagent_type: \"codex:codex-rescue\"' '$HERE/commands/codex-engineer.md'"
chk "codex engineer command avoids direct companion shellout" "! grep -q 'codex-companion.mjs' '$HERE/commands/codex-engineer.md'"
chk "codex engineer command preserves runtime flags" "grep -q -- '--background' '$HERE/commands/codex-engineer.md' && grep -q -- '--wait' '$HERE/commands/codex-engineer.md' && grep -q -- '--model' '$HERE/commands/codex-engineer.md' && grep -q -- '--effort' '$HERE/commands/codex-engineer.md'"
chk "codex engineer command has setup fallback" "grep -q '/codex:setup' '$HERE/commands/codex-engineer.md'"
chk "codex engineer keeps workbench verification owner" "grep -q '/workbench:verify' '$HERE/commands/codex-engineer.md' && grep -qi 'do not mark the task verified' '$HERE/commands/codex-engineer.md'"
chk "codex bridge skill names native engineer command" "grep -q '/workbench:codex-engineer' '$HERE/skills/codex-bridge/SKILL.md'"
chk "codex coordination template names native engineer command" "grep -q '/workbench:codex-engineer' '$HERE/templates/codex/CODEX_COORDINATION.md.tmpl'"

# codex OFF (default) → no CODEX_COORDINATION rendered
bash "$HERE/scripts/init.sh" --name "Acme" --mission "x" --target "$TMP" >/dev/null 2>&1
chk "codex off: no coord file"  "[ ! -f '$TMP/.claude/CODEX_COORDINATION.md' ]"
# codex ON → rendered (via --codex flag the wizard would set, or a pre-written config)
TMP2="$(mktemp -d)"; mkdir -p "$TMP2/.workbench"
printf '{ "workbench":{"version":"0.1.0","initialized_at":"x"}, "project":{"name":"Acme","kind":"existing"}, "way_of_working":{"codex":"rescue-only"}, "lifecycle":{"states":["backlog"],"in_review_cap":10} }' > "$TMP2/.workbench/config.json"
bash "$HERE/scripts/init.sh" --name "Acme" --mission "x" --target "$TMP2" >/dev/null 2>&1
chk "codex on: coord rendered"  "[ -f '$TMP2/.claude/CODEX_COORDINATION.md' ] && grep -q 'Acme' '$TMP2/.claude/CODEX_COORDINATION.md'"
rm -rf "$TMP2"

[ "$fail" = 0 ] && echo "PASS: codex" || { echo "codex test failed"; exit 1; }
