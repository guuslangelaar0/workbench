#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail=0
chk() { if eval "$2"; then echo "ok: $1"; else echo "FAIL: $1" >&2; fail=1; fi; }

chk "doctor script exists" "[ -f '$HERE/scripts/doctor.sh' ]"
chk "doctor command exists" "[ -f '$HERE/commands/doctor.md' ]"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
(cd "$TMP" && git init -q)
bash "$HERE/scripts/init.sh" --name "Doctor" --mission "x" --target "$TMP" >/dev/null 2>&1
OUT="$(bash "$HERE/scripts/doctor.sh" --target "$TMP" 2>/dev/null || true)"
chk "doctor reports config ok" "printf '%s' \"\$OUT\" | grep -q 'Config: ok'"
chk "doctor reports manifest ok" "printf '%s' \"\$OUT\" | grep -q 'Manifest: ok'"
chk "doctor reports drift" "printf '%s' \"\$OUT\" | grep -q 'Drift:'"
chk "doctor reports hooks" "printf '%s' \"\$OUT\" | grep -q 'Hooks:'"
chk "doctor reports lanes" "printf '%s' \"\$OUT\" | grep -q 'Lanes:'"
chk "doctor reports dependencies" "printf '%s' \"\$OUT\" | grep -q 'Dependencies:'"
chk "doctor reports tasks" "printf '%s' \"\$OUT\" | grep -q 'Tasks:'"
chk "doctor reports session state" "printf '%s' \"\$OUT\" | grep -q 'SessionState:'"
chk "doctor reports charter" "printf '%s' \"\$OUT\" | grep -q 'Charter:'"

echo "USER EDIT" >> "$TMP/CLAUDE.md"
OUT2="$(bash "$HERE/scripts/doctor.sh" --target "$TMP" 2>/dev/null || true)"
chk "doctor surfaces edited drift" "printf '%s' \"\$OUT2\" | grep -q 'edited'"

[ "$fail" = 0 ] && echo "PASS: doctor" || { echo "doctor test failed"; exit 1; }
