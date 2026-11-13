#!/usr/bin/env bash
# One actor derivation for mesh.sh, the hooks and the channel server:
# explicit --as / WORKBENCH_MESH_ACTOR > alias map > account name from the
# CLAUDE_CONFIG_DIR basename > `lead` for the default dir; headless `claude -p`
# runs become lane:<name>-<pid>. Plus SessionStart model/advisor detection.
# Offline: a fake workbench-mesh binary records argv; "claude" processes are
# real stub processes (a copy of bash named `claude`) whose pid and argv the
# code under test has to discover on its own.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail=0
chk() { if eval "$2"; then echo "ok: $1"; else echo "FAIL: $1" >&2; fail=1; fi; }

FAKE_PLUGIN="$TMP/plugin"; PROJ="$TMP/project"; WBHOME="$TMP/wbhome"; LOG="$TMP/argv.log"
mkdir -p "$FAKE_PLUGIN/bin" "$PROJ/.workbench/mesh" "$WBHOME/mesh" "$TMP/home/.claude" "$TMP/stub"
cat > "$FAKE_PLUGIN/bin/workbench-mesh" <<'FAKE'
#!/usr/bin/env bash
{ printf 'cmd'; for arg in "$@"; do printf '|%s' "$arg"; done; printf '\n'; } >> "${MESH_FAKE_LOG:?}"
FAKE
chmod +x "$FAKE_PLUGIN/bin/workbench-mesh"
printf '{"mode":"local","host":"127.0.0.1","port":47321,"local_token":"tok"}\n' > "$PROJ/.workbench/mesh/server.json"
cp "$(command -v bash)" "$TMP/stub/claude"

CSWAP="$TMP/sessions/2-dev2_example.com"; mkdir -p "$CSWAP"
ALIASES="$WBHOME/mesh/aliases"
# Never inherit the calling session's identity (the suite is often run from one).
CLEAN=(env -u CLAUDE_PLUGIN_DATA -u CLAUDE_CONFIG_DIR -u CLAUDE_PID -u CLAUDE_CODE_SESSION_ID -u CLAUDE_ENV_FILE
  -u WORKBENCH_MESH_ACTOR -u WORKBENCH_MESH_ACTOR_OWNER -u WORKBENCH_MESH_PROVIDER -u WORKBENCH_MESH_MODEL
  -u WORKBENCH_MESH_SESSION_ID -u WORKBENCH_MESH_ALIASES -u WORKBENCH_MESH_CLAUDE_PID
  HOME="$TMP/home" WORKBENCH_HOME="$WBHOME" CLAUDE_PLUGIN_ROOT="$FAKE_PLUGIN" CLAUDE_PROJECT_DIR="$PROJ" MESH_FAKE_LOG="$LOG")
mesh() { "${CLEAN[@]}" WORKBENCH_MESH_CLAUDE_PID=none "$@" bash "$HERE/scripts/mesh.sh" message team hello; }
last() { tail -n 1 "$LOG"; }

: > "$LOG"; mesh
chk "default ~/.claude config dir posts as session:lead" "last | grep -q -- '|--as|session:lead\$'"
: > "$LOG"; mesh CLAUDE_CONFIG_DIR="$CSWAP"
chk "cswap dir <N>-<name>_<domain> posts as session:<name>" "last | grep -q -- '|--as|session:dev2\$'"
: > "$LOG"; mesh CLAUDE_CONFIG_DIR="$TMP/sessions/4-first_last_example.com"
chk "an underscore in the account name survives (domain is the last _ part)" "last | grep -q -- '|--as|session:first_last\$'"
printf '# account=alias\ndev2 = builder  # the build box\n' > "$ALIASES"
: > "$LOG"; mesh CLAUDE_CONFIG_DIR="$CSWAP"
chk "alias map renames the account" "last | grep -q -- '|--as|session:builder\$'"
: > "$LOG"; mesh CLAUDE_CONFIG_DIR="$CSWAP" WORKBENCH_MESH_ACTOR=session:custom
chk "WORKBENCH_MESH_ACTOR beats the alias map" "last | grep -q -- '|--as|session:custom\$'"
: > "$LOG"; "${CLEAN[@]}" WORKBENCH_MESH_CLAUDE_PID=none CLAUDE_CONFIG_DIR="$CSWAP" WORKBENCH_MESH_ACTOR=session:custom bash "$HERE/scripts/mesh.sh" message team hello --as session:explicit
chk "explicit --as beats WORKBENCH_MESH_ACTOR" "last | grep -q -- '|--as|session:explicit\$' && ! last | grep -q custom"
: > "$LOG"; mesh CLAUDE_CONFIG_DIR="$CSWAP" WORKBENCH_MESH_ACTOR=session:parent WORKBENCH_MESH_ACTOR_OWNER=1
chk "an actor exported by another claude process is not inherited" "last | grep -q -- '|--as|session:builder\$'"
: > "$ALIASES"

# Headless lane: mesh.sh runs as a child of a real `claude -p` stub process.
: > "$LOG"
"${CLEAN[@]}" CLAUDE_CONFIG_DIR="$CSWAP" "$TMP/stub/claude" -c "echo \$\$ > '$TMP/lane.pid'; bash '$HERE/scripts/mesh.sh' message team hello; :" -p --model claude-fable-5-2
LANE_PID="$(cat "$TMP/lane.pid")"
chk "claude -p posts as lane:<name>-<claude pid>" "last | grep -q -- '|--as|lane:dev2-$LANE_PID\$'"
: > "$LOG"
"${CLEAN[@]}" CLAUDE_CONFIG_DIR="$CSWAP" "$TMP/stub/claude" -c "bash '$HERE/scripts/mesh.sh' message team hello; :" --model claude-haiku-5-5
chk "an interactive claude ancestor posts as session:<name>" "last | grep -q -- '|--as|session:dev2\$'"

JSON="$("${CLEAN[@]}" WORKBENCH_MESH_CLAUDE_PID=none CLAUDE_CONFIG_DIR="$CSWAP" CLAUDE_CODE_SESSION_ID=0093387b-aaaa bash "$HERE/scripts/mesh-identity.sh" json 2>/dev/null)"
chk "mesh-identity.sh json is valid and carries the identity fields" "printf '%s' \"\$JSON\" | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d[\"actor\"] == \"session:dev2\" and d[\"account\"] == \"dev2\" and d[\"kind\"] == \"session\", d
assert d[\"session_id\"] == \"0093387b-aaaa\" and d[\"machine\"] and d[\"headless\"] is False, d
'"

# ── SessionStart auto-join: model / provider / advisor detection ──
HOOK="$HERE/hooks/bin/mesh-presence.sh"
run_hook() { # run_hook <input json> <stub claude args...>; the hook runs as a child of the stub
  local input="$1"; shift
  printf '%s' "$input" > "$TMP/hook-input.json"
  "${CLEAN[@]}" WORKBENCH_MESH_HOOK_WAIT=1 CLAUDE_CONFIG_DIR="$CSWAP" CLAUDE_ENV_FILE="$TMP/env-file" \
    "$TMP/stub/claude" -c "echo \$\$ > '$TMP/hook-claude.pid'; bash '$HOOK' < '$TMP/hook-input.json' > '$TMP/hook.out' 2> '$TMP/hook.err'; echo \$? > '$TMP/hook.rc'; :" "$@"
}
has() { last | grep -qF -- "$1"; }

: > "$LOG"; : > "$TMP/env-file"
run_hook '{"hook_event_name":"SessionStart","session_id":"sid-interactive","source":"startup","model":"claude-haiku-5-5","cwd":"/x"}' --model claude-opus-5-5
chk "interactive session: joins as session:<name>" "has '|--as|session:dev2'"
chk "interactive session: model comes from the hook input (beats --model)" "has '|--model|claude-haiku-5-5' && ! has claude-opus-5-5"
chk "interactive session: provider is claude" "has '|--provider|claude'"
chk "interactive session: presence is keyed by session id and claude pid" "has '|--session-id|sid-interactive' && has \"|--pid|\$(cat '$TMP/hook-claude.pid')\""
chk "interactive session: account and machine are tagged" "has '|--account|dev2' && has \"|--machine|\$(hostname)\""
chk "hook prints nothing on stdout and exits 0" "[ ! -s '$TMP/hook.out' ] && [ \"\$(cat '$TMP/hook.rc')\" = 0 ]"
chk "CLAUDE_ENV_FILE exports actor, provider, model and the owning pid" "grep -q '^export WORKBENCH_MESH_ACTOR=session:dev2\$' '$TMP/env-file' && grep -q '^export WORKBENCH_MESH_PROVIDER=claude\$' '$TMP/env-file' && grep -q '^export WORKBENCH_MESH_MODEL=claude-haiku-5-5\$' '$TMP/env-file' && grep -q \"^export WORKBENCH_MESH_ACTOR_OWNER=\$(cat '$TMP/hook-claude.pid')\\\$\" '$TMP/env-file'"

: > "$LOG"
run_hook '{"hook_event_name":"SessionStart","session_id":"sid-lane","source":"startup","cwd":"/x"}' -p --model claude-fable-5-2
chk "claude -p --model claude-fable-5-2: model comes from the command line" "has '|--model|claude-fable-5-2'"
chk "claude -p: joins as lane:<name>-<pid>, busy" "has \"|--as|lane:dev2-\$(cat '$TMP/hook-claude.pid')\" && has '|busy|'"

printf '{\n  "model": "claude-opus-5-5",\n  "advisorModel": "claude-fable-5-2"\n}\n' > "$CSWAP/settings.json"
: > "$LOG"
run_hook '{"hook_event_name":"SessionStart","session_id":"sid-settings","source":"startup"}'
chk "no hook model, no --model: falls back to the account's settings.json" "has '|--model|claude-opus-5-5'"
chk "advisorModel is tagged as a capability" "has '|--capability|advisor:claude-fable-5-2'"
printf '{}\n' > "$CSWAP/settings.json"
: > "$LOG"
run_hook '{"hook_event_name":"SessionStart","session_id":"sid-none","source":"startup"}'
chk "nothing to detect: model is unknown, still joins" "has '|--model|unknown' && has '|--as|session:dev2'"

mv "$PROJ/.workbench/mesh/server.json" "$TMP/server.json.off"
: > "$LOG"
run_hook '{"hook_event_name":"SessionStart","session_id":"sid-nomesh","source":"startup","model":"m"}'
chk "project without a mesh: the hook does nothing and exits 0" "[ ! -s '$LOG' ] && [ \"\$(cat '$TMP/hook.rc')\" = 0 ] && [ ! -s '$TMP/hook.out' ]"
mv "$TMP/server.json.off" "$PROJ/.workbench/mesh/server.json"
chk "hooks.json registers mesh-presence.sh for the session lifecycle" "python3 - '$HERE/hooks/hooks.json' <<'PY'
import json, sys
hooks = json.load(open(sys.argv[1]))['hooks']
for event in ('SessionStart', 'UserPromptSubmit', 'PostToolUse', 'Stop', 'SessionEnd'):
    cmds = [h['command'] for group in hooks.get(event, []) for h in group['hooks']]
    assert any('mesh-presence.sh' in c for c in cmds), event
PY"

# ── the channel server uses the same derivation, per session ──
printf '{"seq":1,"type":"message.sent","room":"team","from":"ui:operator","payload":{"text":"old"}}\n' > "$PROJ/.workbench/mesh/events.jsonl"
INIT_OUT="$(printf '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}\n' | "${CLEAN[@]}" CLAUDE_CONFIG_DIR="$CSWAP" CLAUDE_CODE_SESSION_ID=0093387b-aaaa node "$HERE/scripts/mesh-channel.js" 2>/dev/null)"
chk "channel server posts as the derived actor, not session:lead" "printf '%s' \"\$INIT_OUT\" | grep -q 'You post as session:dev2' && ! printf '%s' \"\$INIT_OUT\" | grep -q 'session:lead'"
CURSOR="$PROJ/.workbench/mesh/channel-session_dev2.0093387b-aaaa.seq"
chk "channel cursor is per session and private" "[ -f '$CURSOR' ] && [ \"\$(stat -c %a '$CURSOR' 2>/dev/null || stat -f %Lp '$CURSOR')\" = 600 ]"

chk "plugin source carries no project-specific names" "! grep -nE 'gbb|beebeeb|BB_[A-Z]' '$HERE/scripts/mesh-identity.sh' '$HERE/scripts/mesh.sh' '$HERE/scripts/mesh-channel.js' '$HERE/hooks/bin/mesh-presence.sh' '$HERE/hooks/bin/mesh-mirror-prompt.sh' '$HERE/bin/workbench-mesh'"

[ "$fail" = 0 ] && echo "PASS: mesh-identity" || { echo "mesh-identity test failed"; exit 1; }
