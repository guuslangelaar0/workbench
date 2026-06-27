#!/usr/bin/env bash
# Spec 4 — context backbone: architecture docs scaffold cumulatively per the
# architecture dial (none/context/containers/components), render cleanly, and carry
# the authored-intent ↔ extracted-reality drift framing.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # workbench
fail=0
chk() { if eval "$2"; then echo "ok: $1"; else echo "FAIL: $1" >&2; fail=1; fi; }

scaffold() { local d; d="$(mktemp -d)"; bash "$HERE/scripts/init.sh" --name "Acme & Co" --level "$1" --profile full --target "$d" >/dev/null 2>&1; printf '%s' "$d"; }

S="$(scaffold solo)"
chk "solo: no architecture dir"        "[ ! -d '$S/.claude/architecture' ]"

P="$(scaffold pair)"
chk "pair: context.md only"            "[ -f '$P/.claude/architecture/context.md' ] && [ ! -f '$P/.claude/architecture/containers.md' ]"

C="$(scaffold crew)"
chk "crew: context + containers"       "[ -f '$C/.claude/architecture/context.md' ] && [ -f '$C/.claude/architecture/containers.md' ]"
chk "crew: no components yet"          "[ ! -f '$C/.claude/architecture/components.md' ]"

F="$(scaffold fleet)"
chk "fleet: all three docs"            "[ -f '$F/.claude/architecture/context.md' ] && [ -f '$F/.claude/architecture/containers.md' ] && [ -f '$F/.claude/architecture/components.md' ]"
chk "fleet: project name rendered (with &)" "grep -q 'Acme & Co' '$F/.claude/architecture/context.md'"
chk "fleet: no unrendered tokens"      "! grep -q '{{' '$F/.claude/architecture/context.md'"
chk "fleet: docs carry drift framing"  "grep -qi 'drift' '$F/.claude/architecture/context.md' && grep -qi 'drift' '$F/.claude/architecture/components.md'"
chk "components.md marks the C4 boundary" "grep -qi 'graphify' '$F/.claude/architecture/components.md'"

# re-scaffold (level-up style) is non-destructive: edit a doc, re-run, edit preserved
echo "EDITED-BY-USER" >> "$F/.claude/architecture/context.md"
bash "$HERE/scripts/init.sh" --name "Acme & Co" --level fleet --profile full --target "$F" >/dev/null 2>&1
chk "architecture docs preserved on re-scaffold" "grep -q 'EDITED-BY-USER' '$F/.claude/architecture/context.md'"

# the skill + command exist
chk "architecture skill exists"        "[ -f '$HERE/skills/architecture/SKILL.md' ]"
chk "architecture command exists"      "[ -f '$HERE/commands/architecture.md' ]"

rm -rf "$S" "$P" "$C" "$F"
[ "$fail" = 0 ] && echo "PASS: architecture" || { echo "architecture test failed"; exit 1; }
