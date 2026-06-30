#!/usr/bin/env bash
# Behavioral tests for task-first parking: tangents become real backlog tasks
# with origin metadata, so Mission Control and the loop can see them.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail=0
chk() { if eval "$2"; then echo "ok: $1"; else echo "FAIL: $1" >&2; fail=1; fi; }

bash "$HERE/scripts/init.sh" --name "Acme" --mission "Test." --target "$TMP" --profile minimal --level pair >/dev/null 2>&1
git -C "$TMP" init -q
git -C "$TMP" checkout -qb feature/checkout-retry

bash "$HERE/scripts/task-new.sh" --title "Ship checkout retry handling" --target "$TMP" --track checkout >/dev/null
bash "$HERE/scripts/lead.sh" set --target "$TMP" --session-id "sess-one" --mode task --active-task 0001 --track checkout --purpose "ship checkout retry handling" >/dev/null

CTX="$TMP/context.txt"
printf 'Observed while testing checkout retry: analytics events double-send after retry failure.\n' > "$CTX"

bash "$HERE/scripts/park.sh" \
  --target "$TMP" \
  --session-id "sess-one" \
  --type bug \
  --title "Fix analytics double-send on retry failure" \
  --origin-task 0001 \
  --origin-purpose "ship checkout retry handling" \
  --context-file "$CTX" >/dev/null

PARKED="$TMP/.claude/tasks/backlog/0002-fix-analytics-double-send-on-retry-failure.md"
chk "parked backlog task created" "[ -f '$PARKED' ]"
chk "parked task type recorded" "grep -qF '**Parked-type:** bug' '$PARKED'"
chk "origin task recorded" "grep -qF '**Origin-task:** 0001' '$PARKED'"
chk "origin purpose recorded" "grep -qF '**Origin-purpose:** ship checkout retry handling' '$PARKED'"
chk "origin session recorded" "grep -qF '**Origin-session:** sess-one' '$PARKED'"
chk "origin branch recorded" "grep -qF '**Origin-branch:** feature/checkout-retry' '$PARKED'"
chk "context copied" "grep -q 'analytics events double-send' '$PARKED'"
chk "_next-id bumped after parked task" "[ \"\$(cat '$TMP/.claude/tasks/_next-id')\" = 0003 ]"

MC="$(cd "$TMP" && bash "$HERE/scripts/mc.sh" --no-build --no-prod)"
chk "mission control sees parked task in backlog" "printf '%s' \"\$MC\" | grep -q '0002'"

[ "$fail" = 0 ] && echo "PASS: park" || { echo "park test failed"; exit 1; }
