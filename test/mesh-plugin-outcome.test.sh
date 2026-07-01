#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
HOME_TMP="$(mktemp -d)"
PIDF="$TMP/mesh.pid"
trap 'kill "$(cat "$PIDF" 2>/dev/null)" >/dev/null 2>&1 || true; rm -rf "$TMP" "$HOME_TMP"' EXIT
fail=0
chk() { if eval "$2"; then echo "ok: $1"; else echo "FAIL: $1" >&2; fail=1; fi; }

bash "$HERE/scripts/init.sh" --name "MeshOutcome" --mission "Test." --target "$TMP" --profile full --level crew >/dev/null 2>&1
cargo build -p workbench-mesh >/dev/null || exit 1

export CLAUDE_PLUGIN_ROOT="$HERE"
export CLAUDE_PROJECT_DIR="$TMP"
export WORKBENCH_HOME="$HOME_TMP"

bash "$HERE/scripts/mesh.sh" start --local --port 0 --pid-file "$PIDF" >"$TMP/start.out" 2>&1 &
for _ in $(seq 1 50); do
  [ -f "$TMP/.workbench/mesh/server.json" ] && [ -s "$PIDF" ] && break
  sleep 0.1
done
bash "$HERE/scripts/mesh.sh" open >>"$TMP/start.out" 2>&1

chk "start prints command center url" "grep -q 'Command center:' '$TMP/start.out'"
chk "start prints local url" "grep -q '127.0.0.1' '$TMP/start.out'"

bash "$HERE/scripts/mesh.sh" availability busy --reason "running checkout tests" >/dev/null
bash "$HERE/scripts/mesh.sh" room lead:checkout >/dev/null
bash "$HERE/scripts/mesh.sh" message lead:checkout "what are you touching?" >/dev/null
bash "$HERE/scripts/mesh.sh" ask session:worker "status?" >/dev/null
bash "$HERE/scripts/mesh.sh" handoff 0042 session:worker >/dev/null
bash "$HERE/scripts/mesh.sh" invite --role worker --ttl-seconds 900 >"$TMP/invite.out"
bash "$HERE/scripts/mesh.sh" who >"$TMP/who.out"
"$HERE/bin/workbench-mesh" snapshot statusline --target "$TMP" --home "$HOME_TMP" >/dev/null

chk "invite prints token" "grep -q '^token: wb_invite_' '$TMP/invite.out'"
chk "who shows local actor or events" "grep -Eq 'session|lead|worker|active' '$TMP/who.out'"
chk "event log contains lead chat" "grep -q 'message.sent' '$TMP/.workbench/mesh/events.jsonl'"
chk "event log contains status request" "grep -q 'message.request_status' '$TMP/.workbench/mesh/events.jsonl'"
chk "event log contains task handoff" "grep -q 'task.handoff' '$TMP/.workbench/mesh/events.jsonl'"
chk "audit contains invite" "grep -q 'invite.created' '$TMP/.workbench/mesh/audit.jsonl'"

STATUSLINE="$(bash "$HERE/hooks/bin/mesh-statusline.sh")"
chk "statusline shows busy state from outcome flow" "printf '%s' \"\$STATUSLINE\" | grep -qi 'busy\\|workbench'"

[ "$fail" = 0 ] && echo "PASS: mesh-plugin-outcome" || { echo "mesh-plugin-outcome test failed"; exit 1; }
