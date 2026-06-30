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
"$BIN" actor spawn --target "$TMP" --home "$HOME_TMP" --kind verifier --parent session:lead --purpose "verify task 0042" --task-id 0042
"$BIN" availability --target "$TMP" --home "$HOME_TMP" busy --reason "running checkout tests"
"$BIN" doing --target "$TMP" --home "$HOME_TMP" "running checkout retry tests"
"$BIN" watch --target "$TMP" --home "$HOME_TMP" session:worker
"$BIN" snapshot statusline --target "$TMP" --home "$HOME_TMP"

chk "room create appends room.created" "grep -q 'room.created' '$TMP/.workbench/mesh/events.jsonl'"
chk "message appends message.sent" "grep -q 'message.sent' '$TMP/.workbench/mesh/events.jsonl'"
chk "ask appends message.request_status" "grep -q 'message.request_status' '$TMP/.workbench/mesh/events.jsonl'"
chk "actor spawn appends actor.spawned" "grep -q 'actor.spawned' '$TMP/.workbench/mesh/events.jsonl'"
chk "availability appends presence.heartbeat" "grep -q 'presence.heartbeat' '$TMP/.workbench/mesh/events.jsonl'"
chk "snapshot writes statusline json" "find '$HOME_TMP/mesh/statusline' -type f -name '*.json' | grep -q ."

[ "$fail" = 0 ] && echo "PASS: mesh-ops" || { echo "mesh-ops test failed"; exit 1; }
