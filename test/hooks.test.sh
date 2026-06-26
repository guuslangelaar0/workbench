#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail=0
chk() { if eval "$2"; then echo "ok: $1"; else echo "FAIL: $1" >&2; fail=1; fi; }

chk "hooks.json exists"        "[ -f '$HERE/hooks/hooks.json' ]"
chk "hooks.json valid JSON"    "python3 -m json.tool '$HERE/hooks/hooks.json' >/dev/null"
chk "has SessionStart"         "grep -q 'SessionStart' '$HERE/hooks/hooks.json'"
chk "has PreCompact"           "grep -q 'PreCompact' '$HERE/hooks/hooks.json'"
chk "has PostToolUse"          "grep -q 'PostToolUse' '$HERE/hooks/hooks.json'"
chk "uses PLUGIN_ROOT"         "grep -q 'CLAUDE_PLUGIN_ROOT' '$HERE/hooks/hooks.json'"
for s in ground-session precompact-checkpoint coord-ping; do
  chk "$s syntactically valid" "bash -n '$HERE/hooks/bin/$s.sh'"
done
# precompact writes a marker for a workbench project, no-ops elsewhere
TMP="$(mktemp -d)"; mkdir -p "$TMP/.workbench"; echo '{"lifecycle":{"in_review_cap":10}}' > "$TMP/.workbench/config.json"
printf '{"trigger":"manual","session_id":"s1"}' | CLAUDE_PROJECT_DIR="$TMP" bash "$HERE/hooks/bin/precompact-checkpoint.sh" >/dev/null 2>&1
chk "precompact wrote marker"  "ls '$TMP/.workbench/checkpoints/'*.json >/dev/null 2>&1"
ND="$(mktemp -d)"; printf '{}' | CLAUDE_PROJECT_DIR="$ND" bash "$HERE/hooks/bin/precompact-checkpoint.sh" >/dev/null 2>&1; echo "rc=$?" >/tmp/pc.$$
chk "precompact no-op elsewhere" "[ \"\$(cat /tmp/pc.$$)\" = 'rc=0' ] && ! ls '$ND/.workbench' >/dev/null 2>&1"
rm -rf "$TMP" "$ND" /tmp/pc.$$

# --- SessionStart presence must be scoped to CLAUDE_PROJECT_DIR, not the cwd ---
PROJ="$(mktemp -d)"; OTHER="$(mktemp -d)"
bash "$HERE/scripts/init.sh" --profile full --name "ProjA" --mission m --target "$PROJ"  >/dev/null 2>&1
bash "$HERE/scripts/init.sh" --profile full --name "ProjB" --mission m --target "$OTHER" >/dev/null 2>&1
NO_COLOR=1 WB_WORKSPACE_ROOT="$PROJ"  WB_SID_OVERRIDE="sidProjAAA"  bash "$PROJ/scripts/coord/wb-coord"  ping projA >/dev/null 2>&1
NO_COLOR=1 WB_WORKSPACE_ROOT="$OTHER" WB_SID_OVERRIDE="sidOtherBBB" bash "$OTHER/scripts/coord/wb-coord" ping projB >/dev/null 2>&1
OUTF="$(mktemp)"
( cd "$OTHER" && NO_COLOR=1 CLAUDE_PROJECT_DIR="$PROJ" bash "$HERE/hooks/bin/ground-session.sh" ) >"$OUTF" 2>/dev/null
chk "ground brief shows this project's session" "grep -q sidProjAAA '$OUTF'"
chk "ground brief hides other project's session" "! grep -q sidOtherBBB '$OUTF'"
rm -rf "$PROJ" "$OTHER" "$OUTF"

[ "$fail" = 0 ] && echo "PASS: hooks" || { echo "hooks test failed"; exit 1; }
