#!/usr/bin/env bash
# Behavioral test for mc.sh: runs the dashboard in a scaffolded project and
# asserts it surfaces the project name, lifecycle states, and a task by id.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # tools/initlab
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail=0
chk() { if eval "$2"; then echo "ok: $1"; else echo "FAIL: $1" >&2; fail=1; fi; }

bash "$HERE/scripts/init.sh" --name "Acme" --mission "Test." --target "$TMP" --profile full >/dev/null 2>&1
bash "$HERE/scripts/task-new.sh" --title "Dash Task" --estimate "~2h" --target "$TMP" >/dev/null
bash "$HERE/scripts/task-move.sh" 0001 in-review --target "$TMP" >/dev/null

out="$(cd "$TMP" && bash "$HERE/scripts/mc.sh" --no-prod --no-build 2>/dev/null)"

chk "prints project name"     "printf '%s' \"\$out\" | grep -q 'Acme'"
chk "shows backlog row"       "printf '%s' \"\$out\" | grep -q 'backlog'"
chk "shows in-review row"     "printf '%s' \"\$out\" | grep -q 'in-review'"
chk "lists the task id 0001"  "printf '%s' \"\$out\" | grep -q '0001'"
chk "shows in-review cap"     "printf '%s' \"\$out\" | grep -qi 'cap'"
chk "exits 0 cleanly"         "(cd '$TMP' && bash '$HERE/scripts/mc.sh' --no-prod --no-build >/dev/null 2>&1)"

[ "$fail" = 0 ] && echo "PASS: mc" || { echo "mc test failed"; exit 1; }
