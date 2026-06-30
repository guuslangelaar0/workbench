#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
HOME_TMP="$(mktemp -d)"
PIDF="$TMP/mesh.pid"
trap 'kill "$(cat "$PIDF" 2>/dev/null)" >/dev/null 2>&1 || true; rm -rf "$TMP" "$HOME_TMP"' EXIT
fail=0
chk() { if eval "$2"; then echo "ok: $1"; else echo "FAIL: $1" >&2; fail=1; fi; }

bash "$HERE/scripts/init.sh" --name "MeshUI" --mission "Test." --target "$TMP" --profile full --level crew >/dev/null 2>&1
BIN="$HERE/target/debug/workbench-mesh"
"$BIN" auth bootstrap --target "$TMP" --home "$HOME_TMP" >/dev/null
"$BIN" serve --target "$TMP" --home "$HOME_TMP" --bind local --port 0 --pid-file "$PIDF" > "$TMP/mesh.log" 2>&1 &
for _ in $(seq 1 50); do [ -f "$TMP/.workbench/mesh/server.json" ] && break; sleep 0.1; done
PORT="$(sed -n 's/.*"port":\([0-9][0-9]*\).*/\1/p' "$TMP/.workbench/mesh/server.json" | head -1)"
TOKEN="$(sed -n 's/.*"local_token":"\([^"]*\)".*/\1/p' "$TMP/.workbench/mesh/server.json" | head -1)"

HTML="$(curl -fsS "http://127.0.0.1:$PORT/" -H "Authorization: Bearer $TOKEN")"
chk "html names command center" "printf '%s' \"\$HTML\" | grep -q 'Workbench Mesh'"
chk "html includes leads view" "printf '%s' \"\$HTML\" | grep -q 'Leads'"
chk "html includes workers view" "printf '%s' \"\$HTML\" | grep -q 'Workers'"
chk "html includes rooms view" "printf '%s' \"\$HTML\" | grep -q 'Rooms'"
chk "html includes jobs view" "printf '%s' \"\$HTML\" | grep -q 'Jobs'"
chk "html includes tasks view" "printf '%s' \"\$HTML\" | grep -q 'Tasks'"
chk "html includes decisions view" "printf '%s' \"\$HTML\" | grep -q 'Decisions'"
chk "html includes invites view" "printf '%s' \"\$HTML\" | grep -q 'Invites'"
chk "html includes audit view" "printf '%s' \"\$HTML\" | grep -q 'Audit'"

CSS="$(curl -fsS "http://127.0.0.1:$PORT/assets/style.css" -H "Authorization: Bearer $TOKEN")"
chk "style defines command rail" "printf '%s' \"\$CSS\" | grep -q 'event-rail'"

JS="$(curl -fsS "http://127.0.0.1:$PORT/assets/app.js" -H "Authorization: Bearer $TOKEN")"
chk "app opens websocket" "printf '%s' \"\$JS\" | grep -q 'WebSocket'"
chk "app posts events" "printf '%s' \"\$JS\" | grep -q '/api/events'"
chk "app creates invites" "printf '%s' \"\$JS\" | grep -q '/api/invites'"
chk "app supports availability" "printf '%s' \"\$JS\" | grep -q 'availability.set'"

UNAUTH_RC=0
curl -fsS "http://127.0.0.1:$PORT/" >/tmp/mesh.ui-unauth.$$ 2>&1 || UNAUTH_RC=$?
chk "html rejects missing auth" "[ '$UNAUTH_RC' -ne 0 ]"
rm -f /tmp/mesh.ui-unauth.$$

UNAUTH_JS_RC=0
curl -fsS "http://127.0.0.1:$PORT/assets/app.js" >/tmp/mesh.ui-js-unauth.$$ 2>&1 || UNAUTH_JS_RC=$?
chk "app js rejects missing auth" "[ '$UNAUTH_JS_RC' -ne 0 ]"
rm -f /tmp/mesh.ui-js-unauth.$$

UNAUTH_CSS_RC=0
curl -fsS "http://127.0.0.1:$PORT/assets/style.css" >/tmp/mesh.ui-css-unauth.$$ 2>&1 || UNAUTH_CSS_RC=$?
chk "style css rejects missing auth" "[ '$UNAUTH_CSS_RC' -ne 0 ]"
rm -f /tmp/mesh.ui-css-unauth.$$

curl -fsS -X POST "http://127.0.0.1:$PORT/api/events" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"type":"message.sent","room":"repo:meshui","from":"ui:owner","payload":{"text":"hello leads"}}' >/dev/null

STATE="$(curl -fsS "http://127.0.0.1:$PORT/api/state" -H "Authorization: Bearer $TOKEN")"
chk "state includes ui message" "printf '%s' \"\$STATE\" | grep -q 'hello leads'"

[ "$fail" = 0 ] && echo "PASS: mesh-command-center" || { echo "mesh-command-center test failed"; exit 1; }
