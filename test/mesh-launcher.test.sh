#!/usr/bin/env bash
# bin/workbench-mesh must find the cached binary without CLAUDE_PLUGIN_DATA
# (a session's Bash tool does not get it) and must never use ANOTHER plugin's
# data dir (the Bash tool can inherit one). Runs against a copied plugin root
# with no target/ so the cargo fallback cannot mask the cache lookup.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail=0
chk() { if eval "$2"; then echo "ok: $1"; else echo "FAIL: $1" >&2; fail=1; fi; }
# Never inherit the calling session's identity or plugin dirs.
CLEAN=(env -u CLAUDE_PLUGIN_DATA -u CLAUDE_PLUGIN_ROOT -u CLAUDE_CONFIG_DIR -u CLAUDE_PID -u CLAUDE_PROJECT_DIR
  -u CLAUDE_CODE_SESSION_ID -u WORKBENCH_MESH_ACTOR -u WORKBENCH_MESH_ACTOR_OWNER -u WORKBENCH_HOME
  -u WORKBENCH_MESH_BOOTSTRAP WORKBENCH_MESH_CLAUDE_PID=none)

PLUG="$TMP/plugin"
mkdir -p "$PLUG/bin" "$PLUG/scripts" "$PLUG/.claude-plugin"
cp "$HERE/bin/workbench-mesh" "$PLUG/bin/"
cp "$HERE"/scripts/mesh*.sh "$PLUG/scripts/"
cp "$HERE/.claude-plugin/plugin.json" "$PLUG/.claude-plugin/"
VERSION="$(sed -n 's/^[[:space:]]*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$PLUG/.claude-plugin/plugin.json" | head -1)"
PLATFORM="linux-x64"   # pinned through the launcher's test hooks below
PIN=(WORKBENCH_MESH_TEST_OS=Linux WORKBENCH_MESH_TEST_ARCH=x86_64)

fake_bin() { # fake_bin <data dir> <label>
  mkdir -p "$1/mesh/bin/$VERSION/$PLATFORM"
  printf '#!/usr/bin/env bash\necho "%s $*"\n' "$2" > "$1/mesh/bin/$VERSION/$PLATFORM/workbench-mesh"
  chmod +x "$1/mesh/bin/$VERSION/$PLATFORM/workbench-mesh"
}

CFG="$TMP/sessions/3-dev3_example.com"
fake_bin "$CFG/plugins/data/workbench-workbench" "WORKBENCH-BIN"
fake_bin "$CFG/plugins/data/codex-openai-codex" "DECOY-BIN"

OUT="$("${CLEAN[@]}" "${PIN[@]}" HOME="$TMP/home" CLAUDE_CONFIG_DIR="$CFG" "$PLUG/bin/workbench-mesh" status --x 2>&1)"; RC=$?
chk "CLAUDE_PLUGIN_DATA unset: finds the cached binary under the config dir" "[ '$RC' = 0 ] && [ \"\$OUT\" = 'WORKBENCH-BIN status --x' ]"

OUT="$("${CLEAN[@]}" "${PIN[@]}" HOME="$TMP/home" CLAUDE_CONFIG_DIR="$CFG" CLAUDE_PLUGIN_DATA="$CFG/plugins/data/codex-openai-codex" "$PLUG/bin/workbench-mesh" who 2>&1)"; RC=$?
chk "CLAUDE_PLUGIN_DATA of another plugin: its binary is never run" "! printf '%s' \"\$OUT\" | grep -q DECOY-BIN"
chk "CLAUDE_PLUGIN_DATA of another plugin: falls back to workbench's own cache" "[ '$RC' = 0 ] && [ \"\$OUT\" = 'WORKBENCH-BIN who' ]"

OUT="$("${CLEAN[@]}" "${PIN[@]}" HOME="$TMP/home" CLAUDE_CONFIG_DIR="$CFG" CLAUDE_PLUGIN_DATA="$CFG/plugins/data/workbench-workbench" "$PLUG/bin/workbench-mesh" who 2>&1)"
chk "CLAUDE_PLUGIN_DATA of workbench itself is still honoured" "[ \"\$OUT\" = 'WORKBENCH-BIN who' ]"

mkdir -p "$TMP/home/.claude"
fake_bin "$TMP/home/.claude/plugins/data/workbench-inline" "DEFAULT-DIR-BIN"
OUT="$("${CLEAN[@]}" "${PIN[@]}" HOME="$TMP/home" "$PLUG/bin/workbench-mesh" who 2>&1)"
chk "default ~/.claude config dir: finds the cached binary" "[ \"\$OUT\" = 'DEFAULT-DIR-BIN who' ]"

# Nothing cached anywhere + a foreign data dir: fail, and leave that dir alone.
EMPTY_CFG="$TMP/sessions/9-none_example.com"
FOREIGN="$EMPTY_CFG/plugins/data/codex-openai-codex"
mkdir -p "$FOREIGN"
OUT="$("${CLEAN[@]}" "${PIN[@]}" HOME="$TMP/home2" CLAUDE_CONFIG_DIR="$EMPTY_CFG" CLAUDE_PLUGIN_DATA="$FOREIGN" \
  WORKBENCH_MESH_RELEASE_BASE_URL="file://$TMP/no-such-release" "$PLUG/bin/workbench-mesh" who 2>&1)"; RC=$?
chk "no cached binary: exits non-zero with the build hint" "[ '$RC' != 0 ] && printf '%s' \"\$OUT\" | grep -q 'cargo build --release -p workbench-mesh'"
chk "no cached binary: nothing is written into the other plugin's data dir" "[ -z \"\$(ls -A '$FOREIGN')\" ]"
chk "no cached binary: bootstrap staged under a workbench data dir instead" "[ -d '$EMPTY_CFG/plugins/data/workbench-workbench/mesh' ]"

# scripts/mesh.sh from a plain Bash tool call: no CLAUDE_PLUGIN_ROOT/DATA at all.
PROJ="$TMP/project"; mkdir -p "$PROJ"
OUT="$(cd "$PROJ" && "${CLEAN[@]}" "${PIN[@]}" HOME="$TMP/home" CLAUDE_CONFIG_DIR="$CFG" bash "$PLUG/scripts/mesh.sh" room lead:checkout 2>&1)"; RC=$?
chk "mesh.sh works from a plain shell (no plugin env)" "[ '$RC' = 0 ] && printf '%s' \"\$OUT\" | grep -q '^WORKBENCH-BIN room create --target $PROJ --name lead:checkout'"

[ "$fail" = 0 ] && echo "PASS: mesh-launcher" || { echo "mesh-launcher test failed"; exit 1; }
