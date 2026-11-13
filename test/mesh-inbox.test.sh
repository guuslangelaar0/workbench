#!/usr/bin/env bash
# mesh.sh inbox: a body larger than a pipe buffer must not kill the script
# (`printf | head -1` under pipefail died with SIGPIPE, exit 141, no output),
# the cursor file is private, and mirrored terminal prompts are not inbound
# messages. Offline: a fake workbench-mesh binary serves `event list`.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail=0
chk() { if eval "$2"; then echo "ok: $1"; else echo "FAIL: $1" >&2; fail=1; fi; }

FAKE_PLUGIN="$TMP/plugin"; PROJ="$TMP/project"
mkdir -p "$FAKE_PLUGIN/bin" "$PROJ/.workbench/mesh" "$TMP/home"
cat > "$FAKE_PLUGIN/bin/workbench-mesh" <<'FAKE'
#!/usr/bin/env bash
# `event list --since N`: events with seq > N, like the real binary.
if [ "${1:-}" = "event" ] && [ "${2:-}" = "list" ]; then
  since=0
  while [ "$#" -gt 0 ]; do [ "$1" = "--since" ] && since="${2:-0}"; shift; done
  python3 -c 'import json, sys
for line in open(sys.argv[1]):
    if json.loads(line)["seq"] > int(sys.argv[2]): sys.stdout.write(line)' "${MESH_FAKE_EVENTS:?}" "$since"
fi
FAKE
chmod +x "$FAKE_PLUGIN/bin/workbench-mesh"
printf '{"mode":"local","host":"127.0.0.1","port":47321,"local_token":"tok"}\n' > "$PROJ/.workbench/mesh/server.json"

# Three inbound hits; the first carries ~100 KiB of text (> the 64 KiB pipe buffer).
python3 - "$TMP/events.jsonl" <<'PY'
import json, sys
big = "BIGSTART " + ("x" * 100 * 1024) + " BIGEND"
events = [
    {"seq": 1, "type": "message.sent", "room": "session:me", "from": "session:peer", "to": "session:me", "payload": {"text": big}},
    {"seq": 2, "type": "message.sent", "room": "session:me", "from": "ui:operator", "to": "session:me", "payload": {"text": "typed in my own terminal", "mirror": True}},
    {"seq": 3, "type": "message.request_status", "room": "session:me", "from": "session:peer", "to": "session:me", "payload": {"question": "status?"}},
    {"seq": 4, "type": "task.handoff", "room": "team", "from": "session:peer", "payload": {"task_id": "0042"}},
    {"seq": 5, "type": "message.sent", "room": "session:other", "from": "session:peer", "to": "session:other", "payload": {"text": "not for me"}},
]
with open(sys.argv[1], "w") as f:
    for e in events:
        f.write(json.dumps(e) + "\n")
PY

CLEAN=(env -u CLAUDE_PLUGIN_DATA -u CLAUDE_CONFIG_DIR -u CLAUDE_PID -u CLAUDE_CODE_SESSION_ID
  -u WORKBENCH_MESH_ACTOR -u WORKBENCH_MESH_ACTOR_OWNER -u WORKBENCH_MESH_SESSION_ID WORKBENCH_MESH_CLAUDE_PID=none
  HOME="$TMP/home" WORKBENCH_HOME="$TMP/home" CLAUDE_PLUGIN_ROOT="$FAKE_PLUGIN" CLAUDE_PROJECT_DIR="$PROJ" MESH_FAKE_EVENTS="$TMP/events.jsonl")

# Repeat: the old failure was a race, so one lucky pass proves nothing.
bad=0
for i in 1 2 3 4 5 6 7 8; do
  rm -f "$PROJ"/.workbench/mesh/inbox-*.seq
  "${CLEAN[@]}" bash "$HERE/scripts/mesh.sh" inbox --as session:me > "$TMP/inbox.out" 2> "$TMP/inbox.err"
  rc=$?
  hits="$(grep -c '^seq=' "$TMP/inbox.out")"
  { [ "$rc" = 0 ] && [ "$hits" = 3 ]; } || { bad=$((bad + 1)); echo "run $i: rc=$rc hits=$hits" >&2; }
done
chk "inbox with a >64 KiB body exits 0 and prints all 3 hits (8 of 8 runs)" "[ '$bad' = 0 ]"
chk "the large body is printed whole" "grep -q 'BIGSTART x' '$TMP/inbox.out' && grep -q 'x BIGEND' '$TMP/inbox.out'"
chk "hits keep their order and fields" "sed -n 2p '$TMP/inbox.out' | grep -q '^seq=1 room=session:me from=session:peer: BIGSTART' && grep -q '^seq=3 room=session:me from=session:peer: status?\$' '$TMP/inbox.out' && grep -q '^seq=4 room=team from=session:peer: 0042\$' '$TMP/inbox.out'"
chk "a mirrored terminal prompt is not delivered as an inbound message" "! grep -q 'typed in my own terminal' '$TMP/inbox.out'"
chk "messages for other actors are not delivered" "! grep -q 'not for me' '$TMP/inbox.out'"
SEQ_FILE="$(ls "$PROJ"/.workbench/mesh/inbox-*.seq 2>/dev/null | head -1)"
chk "the cursor advanced to the log tip" "[ \"\$(cat '$SEQ_FILE')\" = 5 ]"
chk "the cursor file is private (0600)" "[ \"\$(stat -c %a '$SEQ_FILE' 2>/dev/null || stat -f %Lp '$SEQ_FILE')\" = 600 ]"
"${CLEAN[@]}" bash "$HERE/scripts/mesh.sh" inbox --as session:me > "$TMP/inbox2.out" 2>&1
RC2=$?
chk "a second read is empty and exits 0" "[ '$RC2' = 0 ] && grep -q 'mesh inbox for session:me: empty' '$TMP/inbox2.out'"

[ "$fail" = 0 ] && echo "PASS: mesh-inbox" || { echo "mesh-inbox test failed"; exit 1; }
