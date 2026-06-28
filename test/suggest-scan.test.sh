#!/usr/bin/env bash
# SQ-6 — operational suggestion producers (condition-driven, auto-resolving):
# in-review cap, missing/empty charter, plugin-version drift.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCAN="$HERE/scripts/suggest-scan.sh"; SUG="$HERE/scripts/suggest.sh"
fail=0
chk() { if eval "$2"; then echo "ok: $1"; else echo "FAIL: $1" >&2; fail=1; fi; }
has() { [ -f "$1/.workbench/suggestions/$2.suggest" ] && grep -q '^status=open$' "$1/.workbench/suggestions/$2.suggest"; }

DIR="$(mktemp -d)"
bash "$HERE/scripts/init.sh" --name "Scan Co" --level crew --target "$DIR" >/dev/null 2>&1
IR="$DIR/.claude/tasks/in-review"

# fresh crew project: charter rendered with content, in-review empty -> no cap/charter suggestions
bash "$SCAN" --target "$DIR" >/dev/null 2>&1
chk "fresh: no cap suggestion"       "! has '$DIR' inreview-cap"
chk "fresh: no charter suggestion"   "! has '$DIR' charter-missing"

# fill in-review to cap -> warn cap suggestion
for i in $(seq 1 10); do printf '# %04d — t\n**Status:** in-review\n' "$i" > "$IR/000$i-t.md"; done
bash "$SCAN" --target "$DIR" >/dev/null 2>&1
chk "cap hit: warn suggestion filed" "has '$DIR' inreview-cap && grep -q '^severity=warn\$' '$DIR/.workbench/suggestions/inreview-cap.suggest'"

# drain -> auto-resolve (suggestion cleared)
rm -f "$IR"/*.md
bash "$SCAN" --target "$DIR" >/dev/null 2>&1
chk "cap cleared: auto-resolved"     "! has '$DIR' inreview-cap"

# empty charter -> charter suggestion; restore -> resolves
printf '# Charter\n\n## Goal\n{{GOAL}}\n' > "$DIR/.workbench/loop-charter.md"   # only placeholder/heading
bash "$SCAN" --target "$DIR" >/dev/null 2>&1
chk "empty charter: suggestion filed" "has '$DIR' charter-missing"
printf '# Charter\n\n## Goal\nShip the thing by Friday.\n' > "$DIR/.workbench/loop-charter.md"
bash "$SCAN" --target "$DIR" >/dev/null 2>&1
chk "charter filled: auto-resolved"   "! has '$DIR' charter-missing"

# missing charter file -> suggestion
rm -f "$DIR/.workbench/loop-charter.md"
bash "$SCAN" --target "$DIR" >/dev/null 2>&1
chk "missing charter: suggestion filed" "has '$DIR' charter-missing"

# plugin version drift: config version != plugin.json version -> upgrade suggestion
PR="$(mktemp -d)"; mkdir -p "$PR/.claude-plugin" "$PR/scripts"
printf '{"name":"workbench","version":"9.9.9"}' > "$PR/.claude-plugin/plugin.json"
# point the scan's suggest helpers at the real ones via symlink-free copy is overkill; instead
# run the real scan with CLAUDE_PLUGIN_ROOT set to a dir whose plugin.json differs from config.
CLAUDE_PLUGIN_ROOT="$PR" bash "$SCAN" --target "$DIR" >/dev/null 2>&1
chk "version drift: upgrade suggestion" "has '$DIR' plugin-upgrade"
rm -rf "$PR"

rm -rf "$DIR"
[ "$fail" = 0 ] && echo "PASS: suggest-scan" || { echo "suggest-scan test failed"; exit 1; }
