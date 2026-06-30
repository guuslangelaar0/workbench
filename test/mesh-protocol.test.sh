#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail=0
chk() { if eval "$2"; then echo "ok: $1"; else echo "FAIL: $1" >&2; fail=1; fi; }

bash "$HERE/scripts/init.sh" --name "MeshProto" --mission "Test." --target "$TMP" --profile full --level crew >/dev/null 2>&1
BIN="$HERE/target/debug/workbench-mesh"

"$BIN" event append --target "$TMP" --type presence.join --room repo:meshproto --from session:lead \
  --payload-json '{"role":"lead","purpose":"checkout"}' > "$TMP/append.out"

chk "event log created" "[ -f '$TMP/.workbench/mesh/events.jsonl' ]"
chk "append reports seq 1" "grep -q 'seq=1' '$TMP/append.out'"
chk "event envelope has version" "grep -q '\"v\":1' '$TMP/.workbench/mesh/events.jsonl'"
chk "event type stored" "grep -q '\"type\":\"presence.join\"' '$TMP/.workbench/mesh/events.jsonl'"

"$BIN" event append --target "$TMP" --type message.sent --room repo:meshproto --from session:lead \
  --payload-json '{"text":"status?"}' >/dev/null

LIST="$("$BIN" event list --target "$TMP" --since 1)"
chk "list since seq 1 shows second event" "printf '%s' \"\$LIST\" | grep -q 'message.sent'"
chk "list since seq 1 hides first event" "! printf '%s' \"\$LIST\" | grep -q 'presence.join'"

BAD_RC=0
"$BIN" event append --target "$TMP" --type not.valid --room repo:meshproto --from session:lead \
  --payload-json '{}' >/tmp/mesh.bad.$$ 2>&1 || BAD_RC=$?
chk "invalid event type is rejected" "[ '$BAD_RC' -ne 0 ] && grep -qi 'invalid event type' /tmp/mesh.bad.$$"
rm -f /tmp/mesh.bad.$$

[ "$fail" = 0 ] && echo "PASS: mesh-protocol" || { echo "mesh-protocol test failed"; exit 1; }
