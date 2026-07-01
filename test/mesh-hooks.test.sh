#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
HOME_TMP="$(mktemp -d)"
trap 'rm -rf "$TMP" "$HOME_TMP"' EXIT
fail=0
chk() { if eval "$2"; then echo "ok: $1"; else echo "FAIL: $1" >&2; fail=1; fi; }

bash "$HERE/scripts/init.sh" --name "MeshHooks" --mission "Test." --target "$TMP" --profile full --level crew >/dev/null 2>&1
mkdir -p "$HOME_TMP/mesh/statusline"
cat > "$HOME_TMP/mesh/statusline/meshhooks.json" <<'JSON'
{"project":"MeshHooks","current_actor":"checkout lead","availability":"busy","doing":"retry tests","active_count":3,"stale_count":1,"watched":["macbook testing 0042"],"unread_mentions":2}
JSON

OUT="$(WORKBENCH_HOME="$HOME_TMP" CLAUDE_PROJECT_DIR="$TMP" CLAUDE_PLUGIN_ROOT="$HERE" bash "$HERE/hooks/bin/mesh-statusline.sh")"
chk "statusline prints project" "printf '%s' \"\$OUT\" | grep -q 'workbench'"
chk "statusline prints actor" "printf '%s' \"\$OUT\" | grep -q 'checkout lead'"
chk "statusline prints team pulse" "printf '%s' \"\$OUT\" | grep -q '3 active'"
chk "statusline does not require server" "printf '%s' \"\$OUT\" | grep -q 'macbook testing 0042'"

printf '{"session_id":"sidmesh","prompt":"can you ask the macbook session for status?"}' \
  | WORKBENCH_HOME="$HOME_TMP" CLAUDE_PROJECT_DIR="$TMP" CLAUDE_PLUGIN_ROOT="$HERE" bash "$HERE/hooks/bin/mesh-context.sh" > "$TMP/mesh-context.json"
chk "mesh context emits valid json" "python3 -m json.tool '$TMP/mesh-context.json' >/dev/null"
chk "mesh context explains mesh commands" "grep -q '/workbench:mesh' '$TMP/mesh-context.json'"
chk "hooks json references mesh context" "grep -q 'mesh-context.sh' '$HERE/hooks/hooks.json'"

[ "$fail" = 0 ] && echo "PASS: mesh-hooks" || { echo "mesh-hooks test failed"; exit 1; }
