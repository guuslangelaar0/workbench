#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
HOME_TMP="$(mktemp -d)"
trap 'rm -rf "$TMP" "$HOME_TMP"' EXIT
fail=0
chk() { if eval "$2"; then echo "ok: $1"; else echo "FAIL: $1" >&2; fail=1; fi; }

bash "$HERE/scripts/init.sh" --name "MeshHooks" --mission "Test." --target "$TMP" --profile full --level crew >/dev/null 2>&1
mkdir -p "$HOME_TMP/mesh/statusline" "$TMP/.workbench/mesh"
cat > "$HOME_TMP/mesh/statusline/aaa-other.json" <<'JSON'
{"project":"OtherProject","current_actor":"wrong actor","availability":"busy","doing":"wrong cache","active_count":9,"stale_count":8,"watched":["wrong watcher"],"unread_mentions":7}
JSON
cat > "$HOME_TMP/mesh/statusline/meshhooks.json" <<'JSON'
{"project":"MeshHooks","current_actor":"checkout lead","availability":"busy","doing":"retry tests","active_count":3,"stale_count":1,"watched":["macbook testing 0042"],"devices":["macbook"],"unread_mentions":2}
JSON
cat > "$TMP/.workbench/mesh/server.json" <<'JSON'
{"host":"127.0.0.1","port":47321,"local_token":"secret-local-token"}
JSON

OUT="$(WORKBENCH_HOME="$HOME_TMP" CLAUDE_PROJECT_DIR="$TMP" CLAUDE_PLUGIN_ROOT="$HERE" bash "$HERE/hooks/bin/mesh-statusline.sh")"
chk "statusline preserves workbench brand and names project" "printf '%s' \"\$OUT\" | grep -q 'workbench/meshhooks'"
chk "statusline prints actor" "printf '%s' \"\$OUT\" | grep -q 'checkout lead'"
chk "statusline prints team pulse" "printf '%s' \"\$OUT\" | grep -q '3 active'"
chk "statusline does not require server" "printf '%s' \"\$OUT\" | grep -q 'macbook testing 0042'"
chk "statusline prints connected devices" "printf '%s' \"\$OUT\" | grep -q 'devices macbook'"
chk "statusline selects matching project cache" "! printf '%s' \"\$OUT\" | grep -q 'wrong actor'"
chk "statusline avoids network/build/blocking commands" "! grep -Eq '(^|[[:space:];|&])(curl|git|cargo|sleep|jq)([[:space:];|&]|$)' '$HERE/hooks/bin/mesh-statusline.sh'"

NO_MATCH_HOME="$(mktemp -d)"
mkdir -p "$NO_MATCH_HOME/mesh/statusline"
cat > "$NO_MATCH_HOME/mesh/statusline/aaa-other.json" <<'JSON'
{"project":"OtherProject","current_actor":"wrong actor","availability":"busy","doing":"wrong cache","active_count":9,"stale_count":8,"watched":["wrong watcher"],"unread_mentions":7}
JSON
NO_MATCH_OUT="$(WORKBENCH_HOME="$NO_MATCH_HOME" CLAUDE_PROJECT_DIR="$TMP" CLAUDE_PLUGIN_ROOT="$HERE" bash "$HERE/hooks/bin/mesh-statusline.sh")"
chk "statusline exits empty when no matching cache exists" "[ -z \"\$NO_MATCH_OUT\" ]"

printf '{"hook_event_name":"UserPromptSubmit","session_id":"sidmesh","prompt":"can you ask the macbook session for status?"}' \
  | WORKBENCH_HOME="$HOME_TMP" CLAUDE_PROJECT_DIR="$TMP" CLAUDE_PLUGIN_ROOT="$HERE" bash "$HERE/hooks/bin/mesh-context.sh" > "$TMP/mesh-context.json"
chk "mesh context emits valid json" "python3 -m json.tool '$TMP/mesh-context.json' >/dev/null"
chk "mesh context explains mesh commands" "grep -q '/workbench:mesh' '$TMP/mesh-context.json'"
chk "mesh context includes non-secret command center url" "grep -q 'http://127.0.0.1:47321' '$TMP/mesh-context.json'"
chk "mesh context omits local token value" "! grep -q 'secret-local-token' '$TMP/mesh-context.json'"
chk "mesh context omits tokenized url" "! grep -q 'token=' '$TMP/mesh-context.json'"

printf '{"hook_event_name":"SessionStart","session_id":"sidmesh"}' \
  | WORKBENCH_HOME="$HOME_TMP" CLAUDE_PROJECT_DIR="$TMP" CLAUDE_PLUGIN_ROOT="$HERE" bash "$HERE/hooks/bin/mesh-context.sh" > "$TMP/mesh-context-session-explicit.txt"
chk "explicit SessionStart emits raw startup context" "grep -q '^Workbench mesh context:' '$TMP/mesh-context-session-explicit.txt' && ! python3 -m json.tool '$TMP/mesh-context-session-explicit.txt' >/dev/null 2>&1"
chk "explicit SessionStart omits local token" "! grep -q 'secret-local-token' '$TMP/mesh-context-session-explicit.txt'"

printf '{"session_id":"sidmesh"}' \
  | WORKBENCH_HOME="$HOME_TMP" CLAUDE_PROJECT_DIR="$TMP" CLAUDE_PLUGIN_ROOT="$HERE" bash "$HERE/hooks/bin/mesh-context.sh" > "$TMP/mesh-context-session-fallback.txt"
chk "no prompt/event defaults to raw startup context" "grep -q '^Workbench mesh context:' '$TMP/mesh-context-session-fallback.txt' && ! python3 -m json.tool '$TMP/mesh-context-session-fallback.txt' >/dev/null 2>&1"

printf '{"session_id":"sidmesh","prompt":"status please"}' \
  | WORKBENCH_HOME="$HOME_TMP" CLAUDE_PROJECT_DIR="$TMP" CLAUDE_PLUGIN_ROOT="$HERE" bash "$HERE/hooks/bin/mesh-context.sh" > "$TMP/mesh-context-prompt-fallback.json"
chk "prompt without event emits valid UserPromptSubmit json" "python3 -m json.tool '$TMP/mesh-context-prompt-fallback.json' >/dev/null && grep -q 'UserPromptSubmit' '$TMP/mesh-context-prompt-fallback.json'"

printf '{"hookEventName":"UserPromptSubmit","session_id":"sidmesh"}' \
  | WORKBENCH_HOME="$HOME_TMP" CLAUDE_PROJECT_DIR="$TMP" CLAUDE_PLUGIN_ROOT="$HERE" bash "$HERE/hooks/bin/mesh-context.sh" > "$TMP/mesh-context-user-event-only.json"
chk "UserPromptSubmit indication without prompt emits valid json" "python3 -m json.tool '$TMP/mesh-context-user-event-only.json' >/dev/null && grep -q 'UserPromptSubmit' '$TMP/mesh-context-user-event-only.json'"
chk "hooks json references mesh context" "grep -q 'mesh-context.sh' '$HERE/hooks/hooks.json'"

[ "$fail" = 0 ] && echo "PASS: mesh-hooks" || { echo "mesh-hooks test failed"; exit 1; }
