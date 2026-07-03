#!/usr/bin/env bash
# Drives scripts/mesh-channel.js through the Claude Code channel contract:
# initialize handshake (capabilities + instructions), inbound event → channel
# notification with sender/room meta, history-at-startup skipped, self and
# non-inbound events filtered, sender allowlist, and mesh_reply → mesh.sh.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail=0
chk() { if eval "$2"; then echo "ok: $1"; else echo "FAIL: $1" >&2; fail=1; fi; }

mkdir -p "$TMP/project/.workbench/mesh"
EVENTS="$TMP/project/.workbench/mesh/events.jsonl"
# history that must NOT be injected (channel starts at the log tip)
cat > "$EVENTS" <<'JSONL'
{"seq":1,"type":"message.sent","room":"repo:demo","from":"ui:operator","payload":{"text":"old history"}}
JSONL

# stub mesh.sh records reply invocations
cat > "$TMP/mesh-stub.sh" <<STUB
#!/usr/bin/env bash
echo "\$@" >> "$TMP/replies.log"
echo "message: sent seq=99"
STUB
chmod +x "$TMP/mesh-stub.sh"

node "$HERE/test/mesh-channel-driver.js" "$TMP/project" "$EVENTS" "$TMP/mesh-stub.sh" > "$TMP/driver.out" 2> "$TMP/driver.err"
DRIVER_RC=$?
cat "$TMP/driver.out"
chk "driver completed" "[ '$DRIVER_RC' = 0 ]"
chk "reply tool invoked stub with target, text and actor" "grep -q 'message repo:demo Reply from the session --as test-lead' '$TMP/replies.log'"
[ "$fail" = 0 ] && echo "PASS: mesh-channel" || { echo "mesh-channel test failed"; cat "$TMP/driver.err" >&2; exit 1; }
