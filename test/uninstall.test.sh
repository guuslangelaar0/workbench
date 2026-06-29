#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail=0
chk() { if eval "$2"; then echo "ok: $1"; else echo "FAIL: $1" >&2; fail=1; fi; }

chk "uninstall script exists" "[ -f '$HERE/scripts/uninstall.sh' ]"
chk "uninstall command exists" "[ -f '$HERE/commands/uninstall.md' ]"

TMP="$(mktemp -d)"; TMP2=""; TMP3=""; TMP4=""; trap 'rm -rf "$TMP" "$TMP2" "$TMP3" "$TMP4"' EXIT
(cd "$TMP" && git init -q)
bash "$HERE/scripts/init.sh" --name "Uninstall" --mission "x" --target "$TMP" >/dev/null 2>&1

DRY="$(bash "$HERE/scripts/uninstall.sh" --target "$TMP" --dry-run 2>/dev/null || true)"
chk "dry-run lists removals" "printf '%s' \"\$DRY\" | grep -q 'Would remove' && printf '%s' \"\$DRY\" | grep -q 'scripts/coord/wb-coord'"
chk "dry-run keeps files" "[ -f '$TMP/scripts/coord/wb-coord' ] && [ -f '$TMP/CLAUDE.md' ]"

bash "$HERE/scripts/uninstall.sh" --target "$TMP" --apply >/dev/null 2>&1
chk "apply removes unchanged managed file" "[ ! -e '$TMP/scripts/coord/wb-coord' ]"
chk "apply preserves merge file" "[ -f '$TMP/CLAUDE.md' ]"
chk "apply preserves once file" "[ -f '$TMP/.workbench/loop-charter.md' ] && [ -f '$TMP/.claude/tasks/_next-id' ]"
chk "apply removes gitignore lock line" "! grep -qxF '/.claude/locks/' '$TMP/.gitignore' 2>/dev/null"
chk "apply removes hook block" "! grep -q 'wb-coord commit guard' '$TMP/.git/hooks/pre-commit' 2>/dev/null"

TMP2="$(mktemp -d)"
bash "$HERE/scripts/init.sh" --name "Edited" --mission "x" --target "$TMP2" >/dev/null 2>&1
echo "# user edit" >> "$TMP2/scripts/coord/lib.sh"
bash "$HERE/scripts/uninstall.sh" --target "$TMP2" --apply >/dev/null 2>&1
chk "apply preserves edited managed file" "[ -f '$TMP2/scripts/coord/lib.sh' ]"

TMP3="$(mktemp -d)"
bash "$HERE/scripts/init.sh" --name "Data" --mission "x" --target "$TMP3" >/dev/null 2>&1
bash "$HERE/scripts/task-new.sh" --title "Keep Data" --target "$TMP3" >/dev/null
bash "$HERE/scripts/uninstall.sh" --target "$TMP3" --apply --keep-data >/dev/null 2>&1
chk "keep-data preserves tasks" "ls '$TMP3/.claude/tasks/backlog/'*.md >/dev/null 2>&1"
chk "keep-data preserves manifest" "[ -f '$TMP3/.workbench/manifest.json' ]"

TMP4="$(mktemp -d)"
chk "missing manifest refuses apply" "! bash '$HERE/scripts/uninstall.sh' --target '$TMP4' --apply >/dev/null 2>&1"

[ "$fail" = 0 ] && echo "PASS: uninstall" || { echo "uninstall test failed"; exit 1; }
