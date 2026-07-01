#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
HOME_TMP="$(mktemp -d)"
PIDF="$TMP/mesh.pid"
trap 'kill "$(cat "$PIDF" 2>/dev/null)" >/dev/null 2>&1 || true; rm -rf "$TMP" "$HOME_TMP"' EXIT
fail=0
chk() { if eval "$2"; then echo "ok: $1"; else echo "FAIL: $1" >&2; fail=1; fi; }
if ! command -v node >/dev/null 2>&1; then
  echo "FAIL: node runtime is required for command center UI action harness" >&2
  exit 1
fi
post_ui_action() {
  label="$1"
  event_type="$2"
  marker="$3"
  body="$4"
  response="$(curl -fsS -X POST "http://127.0.0.1:$PORT/api/events" \
    -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
    -d "$body")"
  chk "$label accepted by api events" "printf '%s' \"\$response\" | grep -q '\"type\":\"$event_type\"'"
  chk "$label preserves structured payload" "printf '%s' \"\$response\" | grep -q '$marker'"
}

node "$HERE/test/mesh-command-center-action-harness.js" || exit 1

bash "$HERE/scripts/init.sh" --name "MeshUI" --mission "Test." --target "$TMP" --profile full --level crew >/dev/null 2>&1
cargo build -p workbench-mesh >/dev/null || exit 1
BIN="$HERE/target/debug/workbench-mesh"
"$BIN" auth bootstrap --target "$TMP" --home "$HOME_TMP" >/dev/null
"$BIN" serve --target "$TMP" --home "$HOME_TMP" --bind local --port 0 --pid-file "$PIDF" > "$TMP/mesh.log" 2>&1 &
for _ in $(seq 1 50); do [ -f "$TMP/.workbench/mesh/server.json" ] && break; sleep 0.1; done
PORT="$(sed -n 's/.*"port":\([0-9][0-9]*\).*/\1/p' "$TMP/.workbench/mesh/server.json" | head -1)"
TOKEN="$(sed -n 's/.*"local_token":"\([^"]*\)".*/\1/p' "$TMP/.workbench/mesh/server.json" | head -1)"

HTML_HEADERS="$TMP/html.headers"
HTML="$(curl -fsS -D "$HTML_HEADERS" "http://127.0.0.1:$PORT/" -H "Authorization: Bearer $TOKEN")"
chk "html names command center" "printf '%s' \"\$HTML\" | grep -q 'Workbench Mesh'"
chk "html includes leads view" "printf '%s' \"\$HTML\" | grep -q 'Leads'"
chk "html includes workers view" "printf '%s' \"\$HTML\" | grep -q 'Workers'"
chk "html includes rooms view" "printf '%s' \"\$HTML\" | grep -q 'Rooms'"
chk "html includes jobs view" "printf '%s' \"\$HTML\" | grep -q 'Jobs'"
chk "html includes tasks view" "printf '%s' \"\$HTML\" | grep -q 'Tasks'"
chk "html includes decisions view" "printf '%s' \"\$HTML\" | grep -q 'Decisions'"
chk "html includes invites view" "printf '%s' \"\$HTML\" | grep -q 'Invites'"
chk "html includes audit view" "printf '%s' \"\$HTML\" | grep -q 'Audit'"
chk "html response is no-store" "grep -qi '^cache-control: no-store' '$HTML_HEADERS'"
chk "html response has no referrer policy" "grep -qi '^referrer-policy: no-referrer' '$HTML_HEADERS'"

HTML_QUERY="$(curl -fsS "http://127.0.0.1:$PORT/?token=$TOKEN")"
chk "query token html names command center" "printf '%s' \"\$HTML_QUERY\" | grep -q 'Workbench Mesh'"
chk "query token html links tokenized style" "printf '%s' \"\$HTML_QUERY\" | grep -q \"/assets/style.css?token=$TOKEN\""
chk "query token html links tokenized app" "printf '%s' \"\$HTML_QUERY\" | grep -q \"/assets/app.js?token=$TOKEN\""

CSS_HEADERS="$TMP/style.headers"
CSS="$(curl -fsS -D "$CSS_HEADERS" "http://127.0.0.1:$PORT/assets/style.css" -H "Authorization: Bearer $TOKEN")"
chk "style defines command rail" "printf '%s' \"\$CSS\" | grep -q 'event-rail'"
chk "style response is no-store" "grep -qi '^cache-control: no-store' '$CSS_HEADERS'"
chk "style response has no referrer policy" "grep -qi '^referrer-policy: no-referrer' '$CSS_HEADERS'"

JS_HEADERS="$TMP/app.headers"
JS="$(curl -fsS -D "$JS_HEADERS" "http://127.0.0.1:$PORT/assets/app.js" -H "Authorization: Bearer $TOKEN")"
chk "app opens websocket" "printf '%s' \"\$JS\" | grep -q 'WebSocket'"
chk "app posts events" "printf '%s' \"\$JS\" | grep -q '/api/events'"
chk "app creates invites" "printf '%s' \"\$JS\" | grep -q '/api/invites'"
chk "app supports availability" "printf '%s' \"\$JS\" | grep -q 'availability.set'"
chk "app response is no-store" "grep -qi '^cache-control: no-store' '$JS_HEADERS'"
chk "app response has no referrer policy" "grep -qi '^referrer-policy: no-referrer' '$JS_HEADERS'"

CSS_QUERY="$(curl -fsS "http://127.0.0.1:$PORT/assets/style.css?token=$TOKEN")"
chk "query token style defines command rail" "printf '%s' \"\$CSS_QUERY\" | grep -q 'event-rail'"

JS_QUERY="$(curl -fsS "http://127.0.0.1:$PORT/assets/app.js?token=$TOKEN")"
chk "query token app opens websocket" "printf '%s' \"\$JS_QUERY\" | grep -q 'WebSocket'"

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

post_ui_action "request help" "message.help_request" "cmd-help-6" \
  '{"type":"message.help_request","room":"repo:meshui","from":"ui:owner","to":"worker:alpha","payload":{"text":"cmd-help-6","priority":"operator"}}'
post_ui_action "revoke invite" "invite.revoked" "invite-revoke-6" \
  '{"type":"invite.revoked","room":"repo:meshui","from":"ui:owner","to":"worker:alpha","payload":{"token_hint":"invite-revoke-6","reason":"operator revoked"}}'
post_ui_action "approve decision" "decision.answer" "decision-approve-6" \
  '{"type":"decision.answer","room":"repo:meshui","from":"ui:owner","to":"worker:alpha","payload":{"decision":"decision-approve-6","answer":"approved","approved":true}}'
post_ui_action "deny decision" "decision.answer" "decision-deny-6" \
  '{"type":"decision.answer","room":"repo:meshui","from":"ui:owner","to":"worker:alpha","payload":{"decision":"decision-deny-6","answer":"denied","approved":false}}'
post_ui_action "reassign task" "task.reassigned" "task-reassign-6" \
  '{"type":"task.reassigned","room":"repo:meshui","from":"ui:owner","to":"worker:beta","payload":{"task":"task-reassign-6","assignee":"worker:beta"}}'
post_ui_action "stop job" "job.cancelled" "job-stop-6" \
  '{"type":"job.cancelled","room":"repo:meshui","from":"ui:owner","to":"worker:alpha","payload":{"job":"job-stop-6","reason":"operator stopped"}}'
post_ui_action "retry job" "job.queued" "job-retry-6" \
  '{"type":"job.queued","room":"repo:meshui","from":"ui:owner","to":"worker:alpha","payload":{"job":"job-retry-6","retry":true}}'
post_ui_action "adopt stale lead" "lead.adopted" "lead-adopt-6" \
  '{"type":"lead.adopted","room":"repo:meshui","from":"ui:owner","to":"worker:gamma","payload":{"lead":"lead-adopt-6","reason":"stale lead adopted"}}'
post_ui_action "close lead" "lead.closed" "lead-close-6" \
  '{"type":"lead.closed","room":"repo:meshui","from":"ui:owner","to":"worker:delta","payload":{"lead":"lead-close-6","reason":"operator closed"}}'
post_ui_action "set availability" "actor.status" "availability.set" \
  '{"type":"actor.status","room":"repo:meshui","from":"ui:owner","to":"worker:alpha","payload":{"intent":"availability.set","availability":"available"}}'

STATE="$(curl -fsS "http://127.0.0.1:$PORT/api/state" -H "Authorization: Bearer $TOKEN")"
chk "state includes ui message" "printf '%s' \"\$STATE\" | grep -q 'hello leads'"
chk "state includes request help action" "printf '%s' \"\$STATE\" | grep -q 'cmd-help-6'"
chk "state includes revoke invite action" "printf '%s' \"\$STATE\" | grep -q 'invite-revoke-6'"
chk "state includes approve decision action" "printf '%s' \"\$STATE\" | grep -q 'decision-approve-6'"
chk "state includes deny decision action" "printf '%s' \"\$STATE\" | grep -q 'decision-deny-6'"
chk "state includes reassign task action" "printf '%s' \"\$STATE\" | grep -q 'task-reassign-6'"
chk "state includes stop job action" "printf '%s' \"\$STATE\" | grep -q 'job-stop-6'"
chk "state includes retry job action" "printf '%s' \"\$STATE\" | grep -q 'job-retry-6'"
chk "state includes adopt stale lead action" "printf '%s' \"\$STATE\" | grep -q 'lead-adopt-6'"
chk "state includes close lead action" "printf '%s' \"\$STATE\" | grep -q 'lead-close-6'"
chk "state includes availability action" "printf '%s' \"\$STATE\" | grep -q 'availability.set'"

[ "$fail" = 0 ] && echo "PASS: mesh-command-center" || { echo "mesh-command-center test failed"; exit 1; }
