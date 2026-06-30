#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
HOME_TMP="$(mktemp -d)"
LOG="$TMP/mesh.log"
PIDF="$TMP/mesh.pid"
trap 'kill "$(cat "$PIDF" 2>/dev/null)" >/dev/null 2>&1 || true; rm -rf "$TMP" "$HOME_TMP"' EXIT
fail=0
chk() { if eval "$2"; then echo "ok: $1"; else echo "FAIL: $1" >&2; fail=1; fi; }

cargo build -p workbench-mesh >/dev/null || exit 1
bash "$HERE/scripts/init.sh" --name "MeshOps" --mission "Test." --target "$TMP" --profile full --level crew >/dev/null 2>&1
BIN="$HERE/target/debug/workbench-mesh"
"$BIN" auth bootstrap --target "$TMP" --home "$HOME_TMP" >/dev/null

"$BIN" serve --target "$TMP" --home "$HOME_TMP" --bind local --port 0 --pid-file "$PIDF" > "$LOG" 2>&1 &
for _ in $(seq 1 50); do
  [ -f "$TMP/.workbench/mesh/server.json" ] && [ -f "$PIDF" ] && break
  sleep 0.1
done

"$BIN" room create --target "$TMP" --home "$HOME_TMP" --name lead:checkout
"$BIN" message --target "$TMP" --home "$HOME_TMP" --to lead:checkout --text "what are you touching?"
"$BIN" ask --target "$TMP" --home "$HOME_TMP" --to session:worker --question "status?"
"$BIN" handoff --target "$TMP" --home "$HOME_TMP" --task-id 0042 --to session:worker
"$BIN" actor spawn --target "$TMP" --home "$HOME_TMP" --kind verifier --parent session:lead --purpose "verify task 0042" --task-id 0042
"$BIN" availability --target "$TMP" --home "$HOME_TMP" busy --reason "running checkout tests"
"$BIN" doing --target "$TMP" --home "$HOME_TMP" "running checkout retry tests"
"$BIN" watch --target "$TMP" --home "$HOME_TMP" session:worker
STATUSLINE_OUTPUT="$("$BIN" snapshot statusline --target "$TMP" --home "$HOME_TMP")"
SNAPSHOT_PATH="$(find "$HOME_TMP/mesh/statusline" -type f -name '*.json' -print -quit)"

chk "room create appends room.created" "grep -q 'room.created' '$TMP/.workbench/mesh/events.jsonl'"
chk "message appends message.sent" "grep -q 'message.sent' '$TMP/.workbench/mesh/events.jsonl'"
chk "ask appends message.request_status" "grep -q 'message.request_status' '$TMP/.workbench/mesh/events.jsonl'"
chk "handoff appends task.handoff" "grep -q 'task.handoff' '$TMP/.workbench/mesh/events.jsonl'"
chk "actor spawn appends actor.spawned" "grep -q 'actor.spawned' '$TMP/.workbench/mesh/events.jsonl'"
chk "availability appends presence.heartbeat" "grep -q 'presence.heartbeat' '$TMP/.workbench/mesh/events.jsonl'"
chk "doing appends actor.status" "grep -q 'actor.status' '$TMP/.workbench/mesh/events.jsonl'"
chk "watch appends payload intent" "grep -q '\"intent\":\"watch\"' '$TMP/.workbench/mesh/events.jsonl'"
chk "operation payloads include routed data" "python3 - '$TMP/.workbench/mesh/events.jsonl' <<'PY'
import json
import sys

events = []
with open(sys.argv[1], encoding='utf-8') as f:
    for line in f:
        events.append(json.loads(line))

if not any(
    event.get('type') == 'task.handoff'
    and event.get('payload', {}).get('task_id') == '0042'
    and event.get('to') == 'session:worker'
    for event in events
):
    raise SystemExit('missing task.handoff task_id=0042 to=session:worker')

if not any(
    event.get('type') == 'message.sent'
    and event.get('payload', {}).get('text') == 'what are you touching?'
    for event in events
):
    raise SystemExit('missing message.sent text')

if not any(
    event.get('type') == 'message.request_status'
    and event.get('payload', {}).get('question') == 'status?'
    for event in events
):
    raise SystemExit('missing message.request_status question')
PY"
chk "snapshot writes statusline json" "[ -n '$SNAPSHOT_PATH' ]"
chk "snapshot prints compact statusline only" "[ '$STATUSLINE_OUTPUT' = 'workbench | checkout lead | busy: running checkout retry tests | team 3 active, 0 stale' ]"
chk "snapshot json contents" "python3 - '$SNAPSHOT_PATH' <<'PY'
import json
import sys

with open(sys.argv[1], encoding='utf-8') as f:
    snapshot = json.load(f)

expected = {
    'project': 'meshops',
    'current_actor': 'checkout lead',
    'availability': 'busy',
    'doing': 'running checkout retry tests',
    'active_count': 3,
    'stale_count': 0,
    'watched': ['session:worker'],
    'unread_mentions': 0,
}

for key, value in expected.items():
    if snapshot.get(key) != value:
        raise SystemExit(f'{key}: expected {value!r}, got {snapshot.get(key)!r}')

purpose = snapshot.get('purpose')
if purpose is not None:
    raise SystemExit('purpose: expected None, got %r' % (purpose,))
PY"

[ "$fail" = 0 ] && echo "PASS: mesh-ops" || { echo "mesh-ops test failed"; exit 1; }
