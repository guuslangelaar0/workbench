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

bash "$HERE/scripts/init.sh" --name "MeshSvc" --mission "Test." --target "$TMP" --profile full --level crew >/dev/null 2>&1
BIN="$HERE/target/debug/workbench-mesh"
"$BIN" auth bootstrap --target "$TMP" --home "$HOME_TMP" >/dev/null

"$BIN" serve --target "$TMP" --home "$HOME_TMP" --bind local --port 0 --pid-file "$PIDF" > "$LOG" 2>&1 &
for _ in $(seq 1 50); do
  [ -f "$TMP/.workbench/mesh/server.json" ] && [ -f "$PIDF" ] && break
  sleep 0.1
done

PORT="$(sed -n 's/.*"port":\([0-9][0-9]*\).*/\1/p' "$TMP/.workbench/mesh/server.json" | head -1)"
TOKEN="$(sed -n 's/.*"local_token":"\([^"]*\)".*/\1/p' "$TMP/.workbench/mesh/server.json" | head -1)"
chk "server wrote port" "[ -n '$PORT' ]"
chk "server wrote local token" "[ -n '$TOKEN' ]"
chk "server wrote pid file" "[ -s '$PIDF' ]"
chk "scaffold ignores mesh runtime" "grep -qxF '/.workbench/mesh/' '$TMP/.gitignore'"

HEALTH="$(curl -fsS "http://127.0.0.1:$PORT/health" -H "Authorization: Bearer $TOKEN")"
chk "authenticated health returns ok" "printf '%s' \"\$HEALTH\" | grep -q '\"ok\":true'"

UNAUTH_HEALTH_RC=0
curl -fsS "http://127.0.0.1:$PORT/health" >/tmp/mesh.unauth-health.$$ 2>&1 || UNAUTH_HEALTH_RC=$?
chk "health rejects missing auth" "[ '$UNAUTH_HEALTH_RC' -ne 0 ]"
rm -f /tmp/mesh.unauth-health.$$

POST="$(curl -fsS -X POST "http://127.0.0.1:$PORT/api/events" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"type":"presence.join","room":"repo:meshsvc","from":"session:lead","payload":{"role":"lead"}}')"
chk "post event returns seq" "printf '%s' \"\$POST\" | grep -q '\"seq\":1'"

STATE="$(curl -fsS "http://127.0.0.1:$PORT/api/state" -H "Authorization: Bearer $TOKEN")"
chk "state includes active session" "printf '%s' \"\$STATE\" | grep -q 'session:lead'"

WHO="$("$BIN" who --target "$TMP" --home "$HOME_TMP")"
chk "who uses daemon state" "printf '%s' \"\$WHO\" | grep -q 'session:lead'"

BENCH="$("$BIN" bench --target "$TMP" --home "$HOME_TMP" --messages 100)"
chk "bench reports p95 latency" "printf '%s' \"\$BENCH\" | grep -q 'p95_ms='"

UNAUTH_RC=0
curl -fsS "http://127.0.0.1:$PORT/api/state" >/tmp/mesh.unauth.$$ 2>&1 || UNAUTH_RC=$?
chk "api rejects missing auth" "[ '$UNAUTH_RC' -ne 0 ]"
rm -f /tmp/mesh.unauth.$$

[ "$fail" = 0 ] && echo "PASS: mesh-service" || { echo "mesh-service test failed"; exit 1; }
