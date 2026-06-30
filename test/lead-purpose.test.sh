#!/usr/bin/env bash
# Behavioral tests for durable lead purpose: a lead session can set purpose,
# recover latest open purpose, close it, and receive hook context.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail=0
chk() { if eval "$2"; then echo "ok: $1"; else echo "FAIL: $1" >&2; fail=1; fi; }

bash "$HERE/scripts/init.sh" --name "Acme" --mission "Test." --target "$TMP" --profile full --level pair >/dev/null 2>&1
git -C "$TMP" init -q
git -C "$TMP" checkout -qb feature/checkout-retry

LEAD="$HERE/scripts/lead.sh"
HOOK="$HERE/hooks/bin/lead-purpose-nudge.sh"

"$LEAD" set --target "$TMP" --session-id "sess/one" --mode task --active-task 0123 --track checkout --purpose "ship checkout retry handling" >/dev/null
F="$TMP/.workbench/leads/sess-one.lead"

chk "lead file created with sanitized session id" "[ -f '$F' ]"
chk "purpose stored" "grep -q '^purpose=ship checkout retry handling$' '$F'"
chk "mode stored" "grep -q '^mode=task$' '$F'"
chk "active task stored" "grep -q '^active_task=0123$' '$F'"
chk "track stored" "grep -q '^track=checkout$' '$F'"
chk "branch stored" "grep -q '^branch=feature/checkout-retry$' '$F'"
chk "parking policy stored" "grep -q '^parking_policy=backlog-task$' '$F'"

STATUS="$("$LEAD" status --target "$TMP" --session-id "sess/one")"
chk "status prints purpose" "printf '%s' \"\$STATUS\" | grep -q 'ship checkout retry handling'"
chk "status prints task mode" "printf '%s' \"\$STATUS\" | grep -q 'mode=task'"

LATEST="$("$LEAD" latest-open --target "$TMP")"
chk "latest-open finds open purpose" "printf '%s' \"\$LATEST\" | grep -q 'ship checkout retry handling'"

printf '{"session_id":"sess/one","prompt":"also fix unrelated analytics"}' \
  | CLAUDE_PROJECT_DIR="$TMP" CLAUDE_PLUGIN_ROOT="$HERE" bash "$HOOK" > "$TMP/hook.json"
chk "hook emits JSON for current purpose" "python3 -m json.tool '$TMP/hook.json' >/dev/null"
chk "hook context names purpose" "grep -q 'ship checkout retry handling' '$TMP/hook.json'"
chk "hook context instructs parking" "grep -q 'park' '$TMP/hook.json'"
chk "hook sets lead session title" "grep -q 'lead:0123' '$TMP/hook.json'"

"$LEAD" clear --target "$TMP" --session-id "sess/one" >/dev/null
chk "clear marks lead closed" "grep -q '^status=closed$' '$F'"

if "$LEAD" latest-open --target "$TMP" >/tmp/lp.latest.$$ 2>/dev/null; then
  echo "FAIL: latest-open should fail when all leads are closed" >&2; fail=1
else
  echo "ok: latest-open fails when all leads are closed"
fi
rm -f /tmp/lp.latest.$$

[ "$fail" = 0 ] && echo "PASS: lead-purpose" || { echo "lead-purpose test failed"; exit 1; }
