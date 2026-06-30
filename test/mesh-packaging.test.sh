#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail=0
chk() { if eval "$2"; then echo "ok: $1"; else echo "FAIL: $1" >&2; fail=1; fi; }
contains() { grep -Fq "$2" "$1"; }

chk "bin launcher exists" "[ -f '$HERE/bin/workbench-mesh' ]"
chk "bin launcher executable" "[ -x '$HERE/bin/workbench-mesh' ]"
chk "scripts mesh wrapper exists" "[ -f '$HERE/scripts/mesh.sh' ]"
chk "mesh wrapper syntactically valid" "bash -n '$HERE/scripts/mesh.sh'"
chk "mesh command exists" "[ -f '$HERE/commands/mesh.md' ]"
chk "mesh command calls mesh.sh" "grep -q 'scripts/mesh.sh' '$HERE/commands/mesh.md'"
chk "mesh skill exists" "[ -f '$HERE/skills/mesh/SKILL.md' ]"
chk "validate plugin knows bin surface" "bash '$HERE/scripts/validate-plugin.sh' '$HERE' | grep -q 'publishable'"

WRAP_TMP="$(mktemp -d "${TMPDIR:-/tmp}/mesh-wrapper.XXXXXX")"
trap 'rm -rf "$WRAP_TMP"' EXIT
FAKE_PLUGIN="$WRAP_TMP/plugin"
PROJECT_DIR="$WRAP_TMP/project"
MESH_HOME="$WRAP_TMP/home"
LOG="$WRAP_TMP/argv.log"
mkdir -p "$FAKE_PLUGIN/bin" "$PROJECT_DIR/.workbench/mesh" "$MESH_HOME"
cat > "$FAKE_PLUGIN/bin/workbench-mesh" <<'FAKE'
#!/usr/bin/env bash
{
  printf 'cmd'
  for arg in "$@"; do
    printf '|%s' "$arg"
  done
  printf '\n'
} >> "${MESH_FAKE_LOG:?}"

if [ "${1:-}" = "invite" ] && [ "${2:-}" = "create" ]; then
  printf 'token: fake-token\nrole: worker\nexpires: later\nmax_uses: 1\n'
fi
FAKE
chmod +x "$FAKE_PLUGIN/bin/workbench-mesh"
printf '{"host":"127.0.0.1","port":47321}\n' > "$PROJECT_DIR/.workbench/mesh/server.json"

run_wrapper() {
  CLAUDE_PLUGIN_ROOT="$FAKE_PLUGIN" \
  CLAUDE_PROJECT_DIR="$PROJECT_DIR" \
  WORKBENCH_HOME="$MESH_HOME" \
  MESH_FAKE_LOG="$LOG" \
  bash "$HERE/scripts/mesh.sh" "$@"
}

: > "$LOG"
run_wrapper start > "$WRAP_TMP/start.out" 2>&1
chk "wrapper start bootstraps auth" "contains '$LOG' 'cmd|auth|bootstrap|--target|$PROJECT_DIR|--home|$MESH_HOME'"
chk "wrapper start serves local" "contains '$LOG' 'cmd|serve|--target|$PROJECT_DIR|--home|$MESH_HOME|--bind|local'"
chk "wrapper start default output avoids port zero URL" "! contains '$WRAP_TMP/start.out' 'http://127.0.0.1:0'"
chk "wrapper start default output points to metadata" "contains '$WRAP_TMP/start.out' '.workbench/mesh/server.json'"

: > "$LOG"
run_wrapper invite --ttl-seconds 60 > "$WRAP_TMP/invite.out" 2>&1
chk "wrapper invite defaults worker role" "contains '$LOG' 'cmd|invite|create|--target|$PROJECT_DIR|--home|$MESH_HOME|--role|worker|--ttl-seconds|60'"
chk "wrapper invite prints metadata URL" "contains '$WRAP_TMP/invite.out' 'url: http://127.0.0.1:47321'"

: > "$LOG"
run_wrapper connect local-token laptop > "$WRAP_TMP/connect-local.out" 2>&1
chk "wrapper connect local token accepts invite" "contains '$LOG' 'cmd|invite|accept|--target|$PROJECT_DIR|--home|$MESH_HOME|--token|local-token|--device|laptop'"

: > "$LOG"
rc=0
run_wrapper connect http://192.0.2.10:47321 remote-token tablet > "$WRAP_TMP/connect-url.out" 2>&1 || rc=$?
chk "wrapper connect URL fails until Rust supports remote accept" "[ '$rc' -ne 0 ]"
chk "wrapper connect URL explains unsupported remote connect" "contains '$WRAP_TMP/connect-url.out' 'remote URL connect is not supported'"
chk "wrapper connect URL does not discard URL into local accept" "[ ! -s '$LOG' ]"

: > "$LOG"
run_wrapper status > "$WRAP_TMP/status.out" 2>&1
run_wrapper who > "$WRAP_TMP/who.out" 2>&1
run_wrapper room lead:checkout > "$WRAP_TMP/room.out" 2>&1
run_wrapper message lead:checkout hello mesh > "$WRAP_TMP/message.out" 2>&1
chk "wrapper status passes target and home" "contains '$LOG' 'cmd|status|--target|$PROJECT_DIR|--home|$MESH_HOME'"
chk "wrapper who passes target and home" "contains '$LOG' 'cmd|who|--target|$PROJECT_DIR|--home|$MESH_HOME'"
chk "wrapper room emits create argv" "contains '$LOG' 'cmd|room|create|--target|$PROJECT_DIR|--home|$MESH_HOME|--name|lead:checkout'"
chk "wrapper message emits text as one argv" "contains '$LOG' 'cmd|message|--target|$PROJECT_DIR|--home|$MESH_HOME|--to|lead:checkout|--text|hello mesh'"

[ "$fail" = 0 ] && echo "PASS: mesh-packaging" || { echo "mesh-packaging test failed"; exit 1; }
