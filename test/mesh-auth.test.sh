#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
HOME_TMP="$(mktemp -d)"
trap 'rm -rf "$TMP" "$HOME_TMP"' EXIT
fail=0
chk() { if eval "$2"; then echo "ok: $1"; else echo "FAIL: $1" >&2; fail=1; fi; }

bash "$HERE/scripts/init.sh" --name "MeshAuth" --mission "Test." --target "$TMP" --profile full --level crew >/dev/null 2>&1
BIN="$HERE/target/debug/workbench-mesh"

RC=0
"$BIN" invite create --target "$TMP" --home "$HOME_TMP" --role worker --ttl-seconds 900 --max-uses 1 >"$TMP/prebootstrap.out" 2>&1 || RC=$?
chk "invite create before bootstrap fails" "[ '$RC' -ne 0 ] && grep -q 'local owner/operator credential required' '$TMP/prebootstrap.out'"

"$BIN" auth bootstrap --target "$TMP" --home "$HOME_TMP" > "$TMP/bootstrap.out"
chk "bootstrap prints authenticated local user" "grep -q 'local credential ready' '$TMP/bootstrap.out'"
chk "device key stored outside repo" "find '$HOME_TMP/mesh/devices' -type f -name '*.key' | grep -q ."
chk "project credential stored outside repo" "find '$HOME_TMP/mesh/projects' -type f -name '*.cred' | grep -q ."
chk "repo contains no secret key files" "! find '$TMP/.workbench' -name '*.key' -o -name '*.cred' | grep -q ."
BOOTSTRAP_ROLE="$(find "$HOME_TMP/mesh/projects" -type f -name '*.cred' -print -quit | xargs python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["role"])' 2>/dev/null || true)"
chk "bootstrap project credential role is owner" "[ '$BOOTSTRAP_ROLE' = owner ]"

MODE="$(find "$HOME_TMP/mesh/devices" -type f -name '*.key' -print -quit | xargs stat -c '%a' 2>/dev/null || true)"
if [ -n "$MODE" ]; then
  chk "device key mode is 600 on linux" "[ '$MODE' = 600 ]"
else
  echo "ok: device key mode skipped on non-GNU stat"
fi

INVITE="$("$BIN" invite create --target "$TMP" --home "$HOME_TMP" --role worker --ttl-seconds 900 --max-uses 1)"
TOKEN="$(printf '%s\n' "$INVITE" | sed -n 's/^token: //p' | head -1)"
chk "invite prints token" "[ -n '$TOKEN' ]"
chk "invite prints worker role" "printf '%s' \"\$INVITE\" | grep -q 'role: worker'"
chk "invite audit written" "grep -q 'invite.created' '$TMP/.workbench/mesh/audit.jsonl'"

"$BIN" invite accept --target "$TMP" --home "$HOME_TMP" --token "$TOKEN" --device macbook > "$TMP/accept.out"
chk "invite accept prints connected device" "grep -q 'device macbook connected' '$TMP/accept.out'"
chk "accept audit written" "grep -q 'invite.accepted' '$TMP/.workbench/mesh/audit.jsonl'"

RC=0
"$BIN" invite accept --target "$TMP" --home "$HOME_TMP" --token "$TOKEN" --device second >/tmp/mesh.invite.$$ 2>&1 || RC=$?
chk "single-use invite cannot be reused" "[ '$RC' -ne 0 ] && grep -qi 'invite exhausted' /tmp/mesh.invite.$$"
rm -f /tmp/mesh.invite.$$

[ "$fail" = 0 ] && echo "PASS: mesh-auth" || { echo "mesh-auth test failed"; exit 1; }
