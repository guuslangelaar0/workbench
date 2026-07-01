#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
HOST_HOME="$(mktemp -d)"
JOIN_HOME="$(mktemp -d)"
PIDF="$TMP/mesh.pid"
trap 'kill "$(cat "$PIDF" 2>/dev/null)" >/dev/null 2>&1 || true; rm -rf "$TMP" "$HOST_HOME" "$JOIN_HOME"' EXIT
fail=0
chk() { if eval "$2"; then echo "ok: $1"; else echo "FAIL: $1" >&2; fail=1; fi; }

bash "$HERE/scripts/init.sh" --name "MeshRemote" --mission "Test." --target "$TMP" --profile full --level crew >/dev/null 2>&1
cargo build -p workbench-mesh >/dev/null || exit 1
BIN="$HERE/target/debug/workbench-mesh"
"$BIN" auth bootstrap --target "$TMP" --home "$HOST_HOME" >/dev/null
"$BIN" serve --target "$TMP" --home "$HOST_HOME" --bind local --port 0 --pid-file "$PIDF" > "$TMP/mesh.log" 2>&1 &
for _ in $(seq 1 50); do [ -f "$TMP/.workbench/mesh/server.json" ] && break; sleep 0.1; done
PORT="$(sed -n 's/.*"port":\([0-9][0-9]*\).*/\1/p' "$TMP/.workbench/mesh/server.json" | head -1)"
OWNER_TOKEN="$(python3 - "$HOST_HOME" <<'PY'
import glob, json, os, sys
path = glob.glob(os.path.join(sys.argv[1], "mesh/projects/*.cred"))[0]
print(json.load(open(path))["token"])
PY
)"
INVITE="$(CLAUDE_PLUGIN_ROOT="$HERE" CLAUDE_PROJECT_DIR="$TMP" WORKBENCH_HOME="$HOST_HOME" bash "$HERE/scripts/mesh.sh" invite --role worker --ttl-seconds 900 --max-uses 1)"
TOKEN="$(printf '%s\n' "$INVITE" | sed -n 's/^token: //p' | head -1)"
chk "invite prints URL connect command" "printf '%s' \"\$INVITE\" | grep -q '/workbench:mesh connect http://'"
chk "invite does not put token in URL query" "! printf '%s' \"\$INVITE\" | grep -q 'token='"

CONNECT="$(CLAUDE_PLUGIN_ROOT="$HERE" CLAUDE_PROJECT_DIR="$TMP" WORKBENCH_HOME="$JOIN_HOME" bash "$HERE/scripts/mesh.sh" connect "http://127.0.0.1:$PORT" "$TOKEN" laptop)"
chk "remote connect prints connected device" "printf '%s' \"\$CONNECT\" | grep -q 'device laptop connected'"
chk "remote connect writes joining credential outside repo" "[ -f '$JOIN_HOME/mesh/projects/laptop.cred' ]"
chk "remote connect writes joining metadata" "grep -q '127.0.0.1' '$TMP/.workbench/mesh/server.json'"
JOIN_TOKEN="$(python3 - "$JOIN_HOME/mesh/projects/laptop.cred" <<'PY'
import json, sys
print(json.load(open(sys.argv[1]))["token"])
PY
)"
chk "repo contains no clear remote bearer token" "! grep -R \"$JOIN_TOKEN\" '$TMP/.workbench/mesh' >/dev/null 2>&1"
STATE="$(curl -fsS "http://127.0.0.1:$PORT/api/state" -H "Authorization: Bearer $JOIN_TOKEN")"
chk "remote credential reads daemon state" "printf '%s' \"\$STATE\" | grep -q 'devices'"
MSG="$(CLAUDE_PLUGIN_ROOT="$HERE" CLAUDE_PROJECT_DIR="$TMP" WORKBENCH_HOME="$JOIN_HOME" bash "$HERE/scripts/mesh.sh" message repo:meshremote remote hello)"
chk "remote worker message command succeeds" "printf '%s' \"\$MSG\" | grep -q 'message: sent'"
STATE_AFTER_MESSAGE="$(curl -fsS "http://127.0.0.1:$PORT/api/state" -H "Authorization: Bearer $OWNER_TOKEN")"
chk "remote worker message reaches host daemon" "printf '%s' \"\$STATE_AFTER_MESSAGE\" | grep -q 'remote hello'"

DEVICES="$(CLAUDE_PLUGIN_ROOT="$HERE" CLAUDE_PROJECT_DIR="$TMP" WORKBENCH_HOME="$HOST_HOME" bash "$HERE/scripts/mesh.sh" devices)"
chk "devices lists remote laptop" "printf '%s' \"\$DEVICES\" | grep -q 'laptop role=worker'"
CLAUDE_PLUGIN_ROOT="$HERE" CLAUDE_PROJECT_DIR="$TMP" WORKBENCH_HOME="$HOST_HOME" bash "$HERE/scripts/mesh.sh" revoke-device laptop >/dev/null
REVOKED_RC=0
curl -fsS "http://127.0.0.1:$PORT/api/state" -H "Authorization: Bearer $JOIN_TOKEN" >"$TMP/revoked.out" 2>&1 || REVOKED_RC=$?
chk "revoked remote credential is rejected" "[ '$REVOKED_RC' -ne 0 ]"
chk "audit records device revoked" "grep -q 'device.revoked' '$TMP/.workbench/mesh/audit.jsonl'"
chk "owner token still works after revoke" "curl -fsS 'http://127.0.0.1:$PORT/api/state' -H \"Authorization: Bearer $OWNER_TOKEN\" >/dev/null"

[ "$fail" = 0 ] && echo "PASS: mesh-remote-lan" || { echo "mesh-remote-lan test failed"; exit 1; }
