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
