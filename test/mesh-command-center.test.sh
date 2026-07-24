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
"$BIN" serve --target "$TMP" --home "$HOME_TMP" --bind local --port 0 --pid-file "$PIDF" --as forge-lead > "$TMP/mesh.log" 2>&1 &
for _ in $(seq 1 50); do [ -f "$TMP/.workbench/mesh/server.json" ] && break; sleep 0.1; done
PORT="$(sed -n 's/.*"port":\([0-9][0-9]*\).*/\1/p' "$TMP/.workbench/mesh/server.json" | head -1)"
TOKEN="$(sed -n 's/.*"local_token":"\([^"]*\)".*/\1/p' "$TMP/.workbench/mesh/server.json" | head -1)"

# Host identity is stamped into server.json at start (never guessed).
chk "server.json records started_by" "grep -q '\"started_by\":\"forge-lead\"' '$TMP/.workbench/mesh/server.json'"
chk "server.json records started_at" "grep -q '\"started_at\":\"' '$TMP/.workbench/mesh/server.json'"

HTML_HEADERS="$TMP/html.headers"
HTML="$(curl -fsS -D "$HTML_HEADERS" "http://127.0.0.1:$PORT/" -H "Authorization: Bearer $TOKEN")"
chk "html names command center" "printf '%s' \"\$HTML\" | grep -q 'Workbench Mesh'"
chk "html carries the app shell" "printf '%s' \"\$HTML\" | grep -q 'id=\"surface\"'"
chk "html loads the live data layer" "printf '%s' \"\$HTML\" | grep -q 'command-center/live.js'"
chk "html loads every surface module" "for m in bench board host ops docs app; do printf '%s' \"\$HTML\" | grep -q \"command-center/\$m.js\" || exit 1; done"
chk "html response is no-store" "grep -qi '^cache-control: no-store' '$HTML_HEADERS'"
chk "html response has no referrer policy" "grep -qi '^referrer-policy: no-referrer' '$HTML_HEADERS'"

HTML_QUERY="$(curl -fsS "http://127.0.0.1:$PORT/?token=$TOKEN")"
chk "query token html names command center" "printf '%s' \"\$HTML_QUERY\" | grep -q 'Workbench Mesh'"
chk "query token html links tokenized style" "printf '%s' \"\$HTML_QUERY\" | grep -q \"/assets/command-center/style.css?token=$TOKEN\""
chk "query token html links tokenized live layer" "printf '%s' \"\$HTML_QUERY\" | grep -q \"/assets/command-center/live.js?token=$TOKEN\""

CSS_HEADERS="$TMP/style.headers"
curl -fsS -D "$CSS_HEADERS" -o "$TMP/style-surfaces.css" "http://127.0.0.1:$PORT/assets/command-center/style-surfaces.css" -H "Authorization: Bearer $TOKEN"
chk "surface styles define event rail" "grep -q 'event-rail' '$TMP/style-surfaces.css'"
chk "surface styles define the bench" "grep -q 'bench-zone' '$TMP/style-surfaces.css'"
chk "style response is no-store" "grep -qi '^cache-control: no-store' '$CSS_HEADERS'"
chk "style response has no referrer policy" "grep -qi '^referrer-policy: no-referrer' '$CSS_HEADERS'"

curl -fsS -o "$TMP/style.css" "http://127.0.0.1:$PORT/assets/command-center/style.css" -H "Authorization: Bearer $TOKEN"
chk "token styles define light and dark themes" "grep -q 'data-theme=\"dark\"' '$TMP/style.css'"

JS_HEADERS="$TMP/app.headers"
curl -fsS -D "$JS_HEADERS" -o "$TMP/live.js" "http://127.0.0.1:$PORT/assets/command-center/live.js" -H "Authorization: Bearer $TOKEN"
chk "live layer opens websocket" "grep -q 'WebSocket' '$TMP/live.js'"
chk "live layer posts events" "grep -q '/api/events' '$TMP/live.js'"
chk "live layer creates invites" "grep -q '/api/invites' '$TMP/live.js'"
chk "live layer revokes devices" "grep -q '/api/devices/revoke' '$TMP/live.js'"
chk "live layer response is no-store" "grep -qi '^cache-control: no-store' '$JS_HEADERS'"
chk "live layer response has no referrer policy" "grep -qi '^referrer-policy: no-referrer' '$JS_HEADERS'"

curl -fsS -o "$TMP/ops.js" "http://127.0.0.1:$PORT/assets/command-center/ops.js" -H "Authorization: Bearer $TOKEN"
chk "ops surface keeps leads view" "grep -q 'Leads' '$TMP/ops.js'"
chk "ops surface keeps workers view" "grep -q 'Workers' '$TMP/ops.js'"
chk "ops surface keeps rooms view" "grep -q 'Rooms' '$TMP/ops.js'"
chk "ops surface keeps jobs view" "grep -q 'Jobs' '$TMP/ops.js'"
chk "ops surface keeps task reassign" "grep -q 'reassignTask' '$TMP/ops.js'"

curl -fsS -o "$TMP/host.js" "http://127.0.0.1:$PORT/assets/command-center/host.js" -H "Authorization: Bearer $TOKEN"
chk "host surface keeps enrollment/invites" "grep -q 'Enrollment' '$TMP/host.js'"
chk "host surface keeps devices view" "grep -q 'Devices' '$TMP/host.js'"
chk "host surface keeps audit view" "grep -q 'Audit' '$TMP/host.js'"
chk "host surface uses observer backend role" "grep -q \"'observer'\" '$TMP/host.js' && ! grep -q \"'viewer'\" '$TMP/host.js'"

curl -fsS -o "$TMP/style-query.css" "http://127.0.0.1:$PORT/assets/command-center/style-surfaces.css?token=$TOKEN"
chk "query token style defines event rail" "grep -q 'event-rail' '$TMP/style-query.css'"

curl -fsS -o "$TMP/live-query.js" "http://127.0.0.1:$PORT/assets/command-center/live.js?token=$TOKEN"
chk "query token live layer opens websocket" "grep -q 'WebSocket' '$TMP/live-query.js'"

# Every module the HTML references must actually be served (no dead script tags).
BUNDLE_OK=1
for m in style.css style-surfaces.css icons.js data.js ui.js live.js bench.js board.js host.js ops.js docs.js app.js; do
  code="$(curl -sS -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/assets/command-center/$m" -H "Authorization: Bearer $TOKEN")"
  [ "$code" = "200" ] || { echo "asset $m returned $code" >&2; BUNDLE_OK=0; }
done
chk "every referenced bundle asset is served" "[ '$BUNDLE_OK' = 1 ]"

UNKNOWN_ASSET_RC=0
curl -fsS "http://127.0.0.1:$PORT/assets/command-center/../../Cargo.toml" -H "Authorization: Bearer $TOKEN" >/dev/null 2>&1 || UNKNOWN_ASSET_RC=$?
chk "unknown asset paths are rejected" "[ '$UNKNOWN_ASSET_RC' -ne 0 ]"

UNAUTH_RC=0
curl -fsS "http://127.0.0.1:$PORT/" >/tmp/mesh.ui-unauth.$$ 2>&1 || UNAUTH_RC=$?
chk "html rejects missing auth" "[ '$UNAUTH_RC' -ne 0 ]"
rm -f /tmp/mesh.ui-unauth.$$

UNAUTH_JS_RC=0
curl -fsS "http://127.0.0.1:$PORT/assets/command-center/live.js" >/tmp/mesh.ui-js-unauth.$$ 2>&1 || UNAUTH_JS_RC=$?
chk "live layer rejects missing auth" "[ '$UNAUTH_JS_RC' -ne 0 ]"
rm -f /tmp/mesh.ui-js-unauth.$$

UNAUTH_CSS_RC=0
curl -fsS "http://127.0.0.1:$PORT/assets/command-center/style.css" >/tmp/mesh.ui-css-unauth.$$ 2>&1 || UNAUTH_CSS_RC=$?
chk "style css rejects missing auth" "[ '$UNAUTH_CSS_RC' -ne 0 ]"
rm -f /tmp/mesh.ui-css-unauth.$$

# /api/state exposes named host fields, never the bearer secret.
STATE_HOST="$(curl -fsS "http://127.0.0.1:$PORT/api/state" -H "Authorization: Bearer $TOKEN")"
chk "state exposes host started_by" "printf '%s' \"\$STATE_HOST\" | grep -q '\"started_by\":\"forge-lead\"'"
chk "state host omits local_token" "! printf '%s' \"\$STATE_HOST\" | grep -q 'local_token'"

# output.chunk: accepted only in its dedicated output:<actor> room.
post_ui_action "output chunk" "output.chunk" "cargo test -p wb-tailer" \
  '{"type":"output.chunk","room":"output:generator-1","from":"generator-1","payload":{"kind":"tool_call","tool":"Bash","summary":"cargo test -p wb-tailer"}}'
OUTPUT_WRONG_ROOM_RC=0
curl -fsS -X POST "http://127.0.0.1:$PORT/api/events" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"type":"output.chunk","room":"repo:meshui","from":"generator-1","payload":{"kind":"message","summary":"nope"}}' >/dev/null 2>&1 || OUTPUT_WRONG_ROOM_RC=$?
chk "output.chunk rejected outside output rooms" "[ '$OUTPUT_WRONG_ROOM_RC' -ne 0 ]"
CHAT_IN_OUTPUT_RC=0
curl -fsS -X POST "http://127.0.0.1:$PORT/api/events" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"type":"message.sent","room":"output:generator-1","from":"ui:owner","payload":{"text":"nope"}}' >/dev/null 2>&1 || CHAT_IN_OUTPUT_RC=$?
chk "coordination chat rejected in output rooms" "[ '$CHAT_IN_OUTPUT_RC' -ne 0 ]"

# tail: stream-json on stdin → output.chunk events in output:<actor>, stdout teed unchanged.
TAIL_IN="$TMP/tail-input.jsonl"
cat > "$TAIL_IN" <<'JSONL'
{"type":"system","subtype":"init","tools":[]}
{"type":"assistant","message":{"content":[{"type":"text","text":"Running the tailer fixture."},{"type":"tool_use","name":"Bash","input":{"command":"cargo test -p tail-fixture"}}]}}
{"type":"user","message":{"content":[{"type":"tool_result","content":"noisy tool result that must not be forwarded"}]}}
{"type":"result","subtype":"success","result":"fixture complete"}
JSONL
TAIL_OUT="$("$BIN" tail --target "$TMP" --home "$HOME_TMP" --as tail-fixture --provider claude --model sonnet < "$TAIL_IN" 2>"$TMP/tail.err")"
chk "tail tees stdin through to stdout unchanged" "[ \"\$TAIL_OUT\" = \"\$(cat '$TAIL_IN')\" ]"
STATE_TAIL="$(curl -fsS "http://127.0.0.1:$PORT/api/state" -H "Authorization: Bearer $TOKEN")"
chk "tail posts tool-call chunk into output room" "printf '%s' \"\$STATE_TAIL\" | grep -q 'cargo test -p tail-fixture'"
chk "tail posts result message chunk" "printf '%s' \"\$STATE_TAIL\" | grep -q 'result: fixture complete'"
chk "tail announces presence with provider/model" "printf '%s' \"\$STATE_TAIL\" | grep -q '\"reason\":\"tailing session output\"'"
chk "tail never forwards tool results" "! printf '%s' \"\$STATE_TAIL\" | grep -q 'noisy tool result'"
chk "tail chunks land in output:tail-fixture" "printf '%s' \"\$STATE_TAIL\" | grep -q '\"room\":\"output:tail-fixture\"'"

# provider/model round-trip through the doing CLI, same as platform/capabilities.
"$BIN" doing --target "$TMP" --home "$HOME_TMP" "building the tailer" --as generator-1 --platform linux --provider claude --model sonnet >/dev/null
STATE_PRESENCE="$(curl -fsS "http://127.0.0.1:$PORT/api/state" -H "Authorization: Bearer $TOKEN")"
chk "doing reports provider" "printf '%s' \"\$STATE_PRESENCE\" | grep -q '\"provider\":\"claude\"'"
chk "doing reports model" "printf '%s' \"\$STATE_PRESENCE\" | grep -q '\"model\":\"sonnet\"'"

curl -fsS -X POST "http://127.0.0.1:$PORT/api/events" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"type":"message.sent","room":"repo:meshui","from":"ui:owner","payload":{"text":"hello leads"}}' >/dev/null

post_ui_action "request help" "message.help_request" "cmd-help-6" \
  '{"type":"message.help_request","room":"repo:meshui","from":"ui:owner","to":"worker:alpha","payload":{"text":"cmd-help-6","priority":"operator"}}'
INVITE_JSON="$(curl -fsS -X POST "http://127.0.0.1:$PORT/api/invites" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"role":"worker","ttl_seconds":900,"max_uses":2}')"
INVITE_TOKEN="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])' <<<"$INVITE_JSON")"
REVOKE_JSON="$(curl -fsS -X POST "http://127.0.0.1:$PORT/api/invites/revoke" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d "{\"token\":\"$INVITE_TOKEN\"}")"
chk "revoke invite calls real API" "printf '%s' \"\$REVOKE_JSON\" | grep -q '\"ok\":true'"
REVOKED_ACCEPT_RC=0
"$BIN" invite accept --target "$TMP" --home "$HOME_TMP" --token "$INVITE_TOKEN" --device revoked-ui >"$TMP/revoked-accept.out" 2>&1 || REVOKED_ACCEPT_RC=$?
chk "revoked invite cannot be accepted" "[ '$REVOKED_ACCEPT_RC' -ne 0 ] && grep -qi 'invite revoked' '$TMP/revoked-accept.out'"
REMOTE_INVITE="$(curl -fsS -X POST "http://127.0.0.1:$PORT/api/invites" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"role":"worker","ttl_seconds":900,"max_uses":1}')"
REMOTE_TOKEN="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])' <<<"$REMOTE_INVITE")"
curl -fsS -X POST "http://127.0.0.1:$PORT/api/invites/accept" \
  -H 'Content-Type: application/json' \
  -d "{\"token\":\"$REMOTE_TOKEN\",\"device\":\"ui-laptop\",\"expected_project\":\"meshui\"}" >/dev/null
DEVICES_JSON="$(curl -fsS "http://127.0.0.1:$PORT/api/devices" -H "Authorization: Bearer $TOKEN")"
chk "devices api lists accepted device" "printf '%s' \"\$DEVICES_JSON\" | grep -q 'ui-laptop'"
chk "devices api does not leak bearer token" "! printf '%s' \"\$DEVICES_JSON\" | grep -q '\"token\"'"
DEVICE_REVOKE_JSON="$(curl -fsS -X POST "http://127.0.0.1:$PORT/api/devices/revoke" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"device":"ui-laptop"}')"
chk "revoke device calls real API" "printf '%s' \"\$DEVICE_REVOKE_JSON\" | grep -q '\"ok\":true'"
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
chk "audit includes real invite revocation" "grep -q 'invite.revoked' '$TMP/.workbench/mesh/audit.jsonl'"
chk "state includes approve decision action" "printf '%s' \"\$STATE\" | grep -q 'decision-approve-6'"
chk "state includes deny decision action" "printf '%s' \"\$STATE\" | grep -q 'decision-deny-6'"
chk "state includes reassign task action" "printf '%s' \"\$STATE\" | grep -q 'task-reassign-6'"
chk "state includes stop job action" "printf '%s' \"\$STATE\" | grep -q 'job-stop-6'"
chk "state includes retry job action" "printf '%s' \"\$STATE\" | grep -q 'job-retry-6'"
chk "state includes adopt stale lead action" "printf '%s' \"\$STATE\" | grep -q 'lead-adopt-6'"
chk "state includes close lead action" "printf '%s' \"\$STATE\" | grep -q 'lead-close-6'"
chk "state includes availability action" "printf '%s' \"\$STATE\" | grep -q 'availability.set'"
chk "state includes output chunk" "printf '%s' \"\$STATE\" | grep -q 'output:generator-1'"

echo "== flag pre-scan does not corrupt free-text message content (blocker fix) =="
FLAG_PLUGIN="$TMP/flag-test-plugin"
mkdir -p "$FLAG_PLUGIN/bin"
ln -sf "$BIN" "$FLAG_PLUGIN/bin/workbench-mesh"
CLAUDE_PLUGIN_ROOT="$FLAG_PLUGIN" CLAUDE_PROJECT_DIR="$TMP" WORKBENCH_HOME="$HOME_TMP" \
  bash "$HERE/scripts/mesh.sh" message team please use --as flag correctly >/dev/null 2>&1 || true
FLAG_MSG="$(curl -fsS "http://127.0.0.1:$PORT/api/events?since=0" -H "Authorization: Bearer $TOKEN" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for e in data['events']:
    if e.get('type') == 'message.sent' and 'please use' in e.get('payload', {}).get('text', ''):
        print(e['payload']['text'])
        print(e['from'])
")"
chk "free-text message with an embedded --as token is preserved in full" "printf '%s\n' \"\$FLAG_MSG\" | head -1 | grep -qx 'please use --as flag correctly'"
chk "sender identity is not spoofed by the embedded token" "printf '%s\n' \"\$FLAG_MSG\" | sed -n 2p | grep -q '^session:lead$\|^forge-lead$'"

echo "== listen-wait FIFO fallback =="
# Without a running `workbench-mesh listen` connector, listen-wait must fall
# back to the polling inbox --wait path rather than hanging forever.
# Pre-seed the seq cursor for fallback-actor so inbox --wait only watches for
# messages arriving after this point (skipping events from earlier test steps).
mkdir -p "$TMP/.workbench/mesh"
FALLBACK_SEQ="$("$BIN" event list --target "$TMP" --home "$HOME_TMP" --since 0 2>/dev/null | python3 -c '
import json, sys
top = 0
for line in sys.stdin:
    try:
        e = json.loads(line)
        top = max(top, e.get("seq", 0))
    except ValueError:
        pass
print(top)
' 2>/dev/null || echo 0)"
printf '%s\n' "$FALLBACK_SEQ" > "$TMP/.workbench/mesh/inbox-fallback-actor.seq"
# Set up a temporary plugin root so mesh.sh can find the debug binary.
FALLBACK_PLUGIN="$TMP/listen-wait-plugin"
mkdir -p "$FALLBACK_PLUGIN/bin"
ln -sf "$BIN" "$FALLBACK_PLUGIN/bin/workbench-mesh"
LISTEN_WAIT_OUT="$TMP/listen-wait-fallback.out"
CLAUDE_PLUGIN_ROOT="$FALLBACK_PLUGIN" CLAUDE_PROJECT_DIR="$TMP" WORKBENCH_HOME="$HOME_TMP" \
  timeout 10 bash "$HERE/scripts/mesh.sh" listen-wait --as fallback-actor > "$LISTEN_WAIT_OUT" 2>&1 &
lw_pid=$!
sleep 1
"$BIN" message --target "$TMP" --home "$HOME_TMP" --to fallback-actor --text "fallback test" --as sender >/dev/null
wait "$lw_pid" || true
chk "listen-wait fallback receives message" "grep -q 'fallback test' '$LISTEN_WAIT_OUT'"

echo "== invite connect command is copy-pasteable (no <device> placeholder) =="
INVITE_PLUGIN="$TMP/invite-plugin"
mkdir -p "$INVITE_PLUGIN/bin"
ln -sf "$BIN" "$INVITE_PLUGIN/bin/workbench-mesh"
INVITE_TEXT="$(CLAUDE_PLUGIN_ROOT="$INVITE_PLUGIN" CLAUDE_PROJECT_DIR="$TMP" WORKBENCH_HOME="$HOME_TMP" bash "$HERE/scripts/mesh.sh" invite --role worker --ttl-seconds 900 2>&1)"
chk "printed connect command contains no literal <device> placeholder" "! printf '%s\n' \"\$INVITE_TEXT\" | grep -q '<device>'"

echo "== activity --ack-of forwards ack seq to binary (blocker fix) =="
ACTIVITY_PLUGIN="$TMP/activity-ack-plugin"
mkdir -p "$ACTIVITY_PLUGIN/bin"
ln -sf "$BIN" "$ACTIVITY_PLUGIN/bin/workbench-mesh"
# Post a message with no explicit to-field so any actor may ack it.
SENT_RESP="$(curl -fsS -X POST "http://127.0.0.1:$PORT/api/events" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"type":"message.sent","room":"team","from":"forge-lead","payload":{"text":"activity-ack-test"}}')"
SENT_SEQ="$(printf '%s' "$SENT_RESP" | python3 -c 'import json,sys; print(json.load(sys.stdin)["seq"])')"
CLAUDE_PLUGIN_ROOT="$ACTIVITY_PLUGIN" CLAUDE_PROJECT_DIR="$TMP" WORKBENCH_HOME="$HOME_TMP" \
  bash "$HERE/scripts/mesh.sh" activity reading --ack-of "$SENT_SEQ" --as activity-reader >/dev/null 2>&1
ACK_EVENTS="$(curl -fsS "http://127.0.0.1:$PORT/api/events?since=0" -H "Authorization: Bearer $TOKEN")"
READ_FOUND="$(printf '%s' "$ACK_EVENTS" | python3 -c 'import json,sys; events=json.load(sys.stdin).get("events",[]); print("yes" if any(e.get("type")=="message.read" and e.get("ack_of")=='"$SENT_SEQ"' for e in events) else "no")')"
chk "activity --ack-of posts a message.read receipt" "[ '$READ_FOUND' = yes ]"

echo "== start --bind rejects an invalid mode before the success banner =="
BIND_PLUGIN="$TMP/bind-validate-plugin"
mkdir -p "$BIND_PLUGIN/bin"
ln -sf "$BIN" "$BIND_PLUGIN/bin/workbench-mesh"
BIND_PROJECT="$TMP/bind-validate-project"
mkdir -p "$BIND_PROJECT"
BIND_OUT="$TMP/bind-invalid.out"
BIND_RC=0
CLAUDE_PLUGIN_ROOT="$BIND_PLUGIN" CLAUDE_PROJECT_DIR="$BIND_PROJECT" WORKBENCH_HOME="$HOME_TMP" \
  bash "$HERE/scripts/mesh.sh" start --bind bogus >"$BIND_OUT" 2>&1 || BIND_RC=$?
chk "start --bind bogus exits non-zero" "[ '$BIND_RC' -ne 0 ]"
chk "start --bind bogus prints the rejection message" "grep -q \"bind must be 'local' or 'lan'\" '$BIND_OUT'"
chk "start --bind bogus never prints the success banner" "! grep -q 'Workbench mesh will listen on' '$BIND_OUT'"

BIND_OK_PROJECT="$TMP/bind-validate-ok-project"
mkdir -p "$BIND_OK_PROJECT"
BIND_OK_OUT="$TMP/bind-valid.out"
CLAUDE_PLUGIN_ROOT="$BIND_PLUGIN" CLAUDE_PROJECT_DIR="$BIND_OK_PROJECT" WORKBENCH_HOME="$HOME_TMP" \
  timeout 2 bash "$HERE/scripts/mesh.sh" start --bind local --port 0 >"$BIND_OK_OUT" 2>&1
chk "start --bind local (valid mode) still prints the success banner" "grep -q 'Workbench mesh will listen on this machine only' '$BIND_OK_OUT'"

echo "== listen forwards --as ACTOR to the workbench-mesh listen connector =="
LISTEN_PLUGIN="$TMP/listen-plugin"
mkdir -p "$LISTEN_PLUGIN/bin"
ln -sf "$BIN" "$LISTEN_PLUGIN/bin/workbench-mesh"
LISTEN_PROJECT="$TMP/listen-project"
mkdir -p "$LISTEN_PROJECT"
LISTEN_OUT="$TMP/listen-forward.out"
LISTEN_RC=0
CLAUDE_PLUGIN_ROOT="$LISTEN_PLUGIN" CLAUDE_PROJECT_DIR="$LISTEN_PROJECT" WORKBENCH_HOME="$HOME_TMP" \
  timeout 4 bash "$HERE/scripts/mesh.sh" listen --as someone >"$LISTEN_OUT" 2>&1 || LISTEN_RC=$?
# No server is running for $LISTEN_PROJECT, so the Rust connector's reconnect
# loop (workbench-mesh listen) retries forever until `timeout` kills it (rc
# 124) — that failure mode (visible as "listen: connection error ...,
# reconnecting" on stderr) proves the wrapper forwarded --target/--as
# correctly and the process is doing real reconnect work, not choking on
# argument parsing in the shell wrapper itself.
chk "listen reaches the Rust binary's reconnect loop" "grep -q 'listen: connection error' '$LISTEN_OUT'"
chk "listen does not fail on a shell-wrapper argument error" "! grep -qi 'requires --as\|unknown operation' '$LISTEN_OUT'"
chk "listen keeps running until timeout kills it (rc 124)" "[ '$LISTEN_RC' -eq 124 ]"
LISTEN_NO_ACTOR_RC=0
CLAUDE_PLUGIN_ROOT="$LISTEN_PLUGIN" CLAUDE_PROJECT_DIR="$LISTEN_PROJECT" WORKBENCH_HOME="$HOME_TMP" \
  bash "$HERE/scripts/mesh.sh" listen >"$TMP/listen-no-actor.out" 2>&1 || LISTEN_NO_ACTOR_RC=$?
chk "listen without --as (and no WORKBENCH_MESH_ACTOR) fails fast" "[ '$LISTEN_NO_ACTOR_RC' -ne 0 ] && grep -q 'listen requires --as ACTOR' '$TMP/listen-no-actor.out'"

echo "== full TLS lan enrollment via scripts/mesh.sh: bare host + --fingerprint + --yes (Task 13) =="
# Real end-to-end coverage through the actual shell entry point, not direct
# Rust calls: start --lan, invite (fingerprint + code printed), connect from a
# second project directory using a bare host (no scheme, no port) plus the
# --fingerprint/--yes pass-through this task added, then a message round-trip
# over the pinned TLS connection. This is the one test in the plan that would
# catch a bug in mesh.sh's own argument assembly rather than the underlying
# Rust functions (already covered directly by crates/workbench-mesh's suite).
LAN_PLUGIN="$TMP/lan-connect-plugin"
mkdir -p "$LAN_PLUGIN/bin"
ln -sf "$BIN" "$LAN_PLUGIN/bin/workbench-mesh"
LAN_HOST_PROJECT="$TMP/lan-host-project"
LAN_JOIN_PROJECT="$TMP/lan-join-project"
LAN_HOST_HOME="$TMP/lan-host-home"
LAN_JOIN_HOME="$TMP/lan-join-home"
mkdir -p "$LAN_HOST_PROJECT" "$LAN_JOIN_PROJECT" "$LAN_HOST_HOME" "$LAN_JOIN_HOME"
LAN_PIDF="$TMP/lan-mesh.pid"
# Same --name on both sides: project identity is derived from
# .workbench/config.json's project.name, and the host only issues a
# credential when the joiner's expected_project matches its own — this is
# what makes two independent temp directories behave like the same project
# checked out on two machines.
bash "$HERE/scripts/init.sh" --name "MeshLanConnect" --mission "Test." --target "$LAN_HOST_PROJECT" --profile full --level crew >/dev/null 2>&1
bash "$HERE/scripts/init.sh" --name "MeshLanConnect" --mission "Test." --target "$LAN_JOIN_PROJECT" --profile full --level crew >/dev/null 2>&1

LAN_START_OUT="$TMP/lan-start.out"
CLAUDE_PLUGIN_ROOT="$LAN_PLUGIN" CLAUDE_PROJECT_DIR="$LAN_HOST_PROJECT" WORKBENCH_HOME="$LAN_HOST_HOME" \
  bash "$HERE/scripts/mesh.sh" start --lan --port 0 --pid-file "$LAN_PIDF" >"$LAN_START_OUT" 2>&1 &
for _ in $(seq 1 50); do [ -f "$LAN_HOST_PROJECT/.workbench/mesh/server.json" ] && break; sleep 0.1; done
chk "lan start banner prints https, not the old bare loopback command-center line" "grep -q '^Host: https://' '$LAN_START_OUT' && ! grep -q '^Command center: http://127.0.0.1' '$LAN_START_OUT'"

LAN_INVITE_OUT="$(CLAUDE_PLUGIN_ROOT="$LAN_PLUGIN" CLAUDE_PROJECT_DIR="$LAN_HOST_PROJECT" WORKBENCH_HOME="$LAN_HOST_HOME" \
  bash "$HERE/scripts/mesh.sh" invite --role worker --ttl-seconds 900)"
LAN_TOKEN="$(printf '%s\n' "$LAN_INVITE_OUT" | sed -n 's/^token: //p' | head -1)"
LAN_FINGERPRINT="$(printf '%s\n' "$LAN_INVITE_OUT" | sed -n 's/.*--fingerprint \(sha256:[^ ]*\).*/\1/p' | head -1)"
chk "lan invite prints a human fingerprint code" "printf '%s\n' \"\$LAN_INVITE_OUT\" | grep -qE '^Fingerprint code: [0-9]{3}-[0-9]{3}$'"
chk "lan invite connect line uses https, not http" "printf '%s\n' \"\$LAN_INVITE_OUT\" | grep -q '/workbench:mesh connect https://'"
chk "lan invite captured a token" "[ -n '$LAN_TOKEN' ]"
chk "lan invite captured a --fingerprint sha256:... value" "[ -n '$LAN_FINGERPRINT' ]"

LAN_CONNECT_OUT="$(CLAUDE_PLUGIN_ROOT="$LAN_PLUGIN" CLAUDE_PROJECT_DIR="$LAN_JOIN_PROJECT" WORKBENCH_HOME="$LAN_JOIN_HOME" \
  bash "$HERE/scripts/mesh.sh" connect 127.0.0.1 "$LAN_TOKEN" seconddevice --fingerprint "$LAN_FINGERPRINT" --yes 2>&1)"
chk "bare-host connect with --fingerprint/--yes pass-through succeeds" "printf '%s' \"\$LAN_CONNECT_OUT\" | grep -q 'device seconddevice connected'"
chk "bare-host connect persists the joining credential outside the repo" "[ -f '$LAN_JOIN_HOME/mesh/projects/seconddevice.cred' ]"

LAN_MSG_OUT="$(CLAUDE_PLUGIN_ROOT="$LAN_PLUGIN" CLAUDE_PROJECT_DIR="$LAN_JOIN_PROJECT" WORKBENCH_HOME="$LAN_JOIN_HOME" \
  bash "$HERE/scripts/mesh.sh" message team lan-e2e-hello --as seconddevice 2>&1)"
chk "joiner message command succeeds over the pinned TLS connection" "printf '%s' \"\$LAN_MSG_OUT\" | grep -q 'message: sent'"
LAN_MSG_SEEN=0
for _ in $(seq 1 30); do
  grep -q 'lan-e2e-hello' "$LAN_HOST_PROJECT/.workbench/mesh/events.jsonl" 2>/dev/null && { LAN_MSG_SEEN=1; break; }
  sleep 0.1
done
chk "joiner message round-trips to the host event log" "[ '$LAN_MSG_SEEN' = 1 ]"

kill "$(cat "$LAN_PIDF" 2>/dev/null)" >/dev/null 2>&1 || true

[ "$fail" = 0 ] && echo "PASS: mesh-command-center" || { echo "mesh-command-center test failed"; exit 1; }
