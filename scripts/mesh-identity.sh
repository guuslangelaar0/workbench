#!/usr/bin/env bash
# The ONE place a Claude session's mesh identity is derived. Sourced by
# scripts/mesh.sh and the mesh hooks; executed once at startup by
# scripts/mesh-channel.js. Pure bash + coreutils (python3 only as an optional
# nicety for reading settings.json), so it works wherever the launcher does.
#
# Actor precedence:
#   1. an explicit name (--as)
#   2. WORKBENCH_MESH_ACTOR — unless it was exported by ANOTHER Claude process
#      (WORKBENCH_MESH_ACTOR_OWNER names the claude pid that exported it; a
#      nested `claude -p` started from a session's Bash tool inherits the
#      variable and must not also inherit the name)
#   3. the alias map: ${WORKBENCH_MESH_ALIASES:-<workbench home>/mesh/aliases},
#      lines of `account=alias` (# comments allowed)
#   4. the account name from the CLAUDE_CONFIG_DIR basename:
#      `<N>-<name>_<domain>` -> `<name>`; any other basename as-is
#   5. `lead` for the default config dir (~/.claude, or CLAUDE_CONFIG_DIR unset)
#
# Interactive sessions are `session:<name>`; headless `claude -p` runs are
# `lane:<name>-<claude pid>`, so parallel lanes on one account stay distinct.
# Two interactive sessions on one account share `session:<name>` on purpose:
# presence, cursors and waiters are keyed by SESSION ID (wb_mesh_session_id),
# not by actor name.

wb_mesh_home() {
  printf '%s\n' "${WORKBENCH_HOME:-$HOME/.workbench}"
}

wb_mesh_config_dir() {
  printf '%s\n' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
}

# Keep actor names to a conservative charset: they end up in file names and
# room names.
wb_mesh_sanitize() {
  printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '-' | sed 's/^-*//; s/-*$//'
}

# The account behind the active Claude config dir.
wb_mesh_account() {
  local dir base name
  dir="$(wb_mesh_config_dir)"
  dir="${dir%/}"
  base="${dir##*/}"
  case "$base" in
    .claude|'') name="lead" ;;
    [0-9]*-*_*) name="${base#*-}"; name="${name%_*}" ;;
    [0-9]*-*) name="${base#*-}" ;;
    *) name="$base" ;;
  esac
  name="$(wb_mesh_sanitize "$name")"
  printf '%s\n' "${name:-lead}"
}

wb_mesh_alias_file() {
  printf '%s\n' "${WORKBENCH_MESH_ALIASES:-$(wb_mesh_home)/mesh/aliases}"
}

# The display name for an account: its alias when the map has one.
wb_mesh_name() {
  local account="${1:-$(wb_mesh_account)}" file key value alias=""
  file="$(wb_mesh_alias_file)"
  if [ -r "$file" ]; then
    while IFS='=' read -r key value || [ -n "$key" ]; do
      key="${key#"${key%%[![:space:]]*}"}"; key="${key%"${key##*[![:space:]]}"}"
      case "$key" in ''|'#'*) continue ;; esac
      value="${value%%#*}"
      value="${value#"${value%%[![:space:]]*}"}"; value="${value%"${value##*[![:space:]]}"}"
      if [ "$key" = "$account" ] && [ -n "$value" ]; then
        alias="$(wb_mesh_sanitize "$value")"
      fi
    done < "$file"
  fi
  printf '%s\n' "${alias:-$account}"
}

# argv of a process, one argument per line. Linux reads /proc (exact);
# elsewhere `ps` (whitespace-split, good enough for flag detection).
wb_mesh_proc_args() {
  local pid="$1"
  if [ -r "/proc/$pid/cmdline" ]; then
    tr '\0' '\n' < "/proc/$pid/cmdline"
  else
    ps -o args= -p "$pid" 2>/dev/null | tr -s ' ' '\n'
  fi
}

wb_mesh_is_claude_pid() {
  local pid="$1" argv0
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  argv0="$(wb_mesh_proc_args "$pid" | head -n 1)"
  [ "${argv0##*/}" = "claude" ]
}

# The Claude process this code runs under: WORKBENCH_MESH_CLAUDE_PID (set by
# callers that know it, e.g. the channel server's parent pid; `none` disables
# detection), then CLAUDE_PID (Claude Code sets it for hooks and the Bash
# tool), then the nearest ancestor whose argv[0] is `claude`. Empty when none.
wb_mesh_claude_pid() {
  local pid="${WORKBENCH_MESH_CLAUDE_PID:-}" hops
  if [ "$pid" = "none" ]; then return 0; fi
  if [ -z "$pid" ]; then pid="${CLAUDE_PID:-}"; fi
  case "$pid" in
    ''|*[!0-9]*) pid="" ;;
    *) kill -0 "$pid" 2>/dev/null || pid="" ;;
  esac
  if [ -n "$pid" ]; then printf '%s\n' "$pid"; return 0; fi
  pid="$PPID"
  for hops in 1 2 3 4 5 6 7 8 9 10; do
    case "$pid" in ''|*[!0-9]*|0|1) return 0 ;; esac
    if wb_mesh_is_claude_pid "$pid"; then printf '%s\n' "$pid"; return 0; fi
    pid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')"
  done
  return 0
}

# Exit 0 when the Claude process is a headless `-p` / `--print` run.
wb_mesh_is_headless() {
  local pid="${1:-$(wb_mesh_claude_pid)}"
  [ -n "$pid" ] || return 1
  wb_mesh_proc_args "$pid" | grep -qxE -- '-p|--print'
}

# The actor this process posts as. $1 = an explicit name (may be empty).
# WB_MESH_STRICT=1 answers only from the explicit name or the environment and
# prints nothing otherwise (for callers that refuse to guess).
wb_mesh_actor() {
  local explicit="${1:-}" pid name env_actor="${WORKBENCH_MESH_ACTOR:-}" owner="${WORKBENCH_MESH_ACTOR_OWNER:-}"
  if [ -n "${explicit//[[:space:]]/}" ]; then printf '%s\n' "$explicit"; return 0; fi
  pid="$(wb_mesh_claude_pid)"
  if [ -n "${env_actor//[[:space:]]/}" ]; then
    if [ -z "$owner" ] || [ "$owner" = "$pid" ]; then printf '%s\n' "$env_actor"; return 0; fi
  fi
  [ "${WB_MESH_STRICT:-0}" = 1 ] && return 0
  name="$(wb_mesh_name)"
  if [ -n "$pid" ] && wb_mesh_is_headless "$pid"; then
    printf 'lane:%s-%s\n' "$name" "$pid"
  else
    printf 'session:%s\n' "$name"
  fi
}

# The session id that keys presence, cursors and waiters. Hooks pass the id
# from their input; elsewhere Claude Code exports CLAUDE_CODE_SESSION_ID.
wb_mesh_session_id() {
  local sid="${1:-}"
  [ -n "$sid" ] || sid="${WORKBENCH_MESH_SESSION_ID:-}"
  [ -n "$sid" ] || sid="${CLAUDE_CODE_SESSION_ID:-}"
  wb_mesh_sanitize "$sid"
  printf '\n'
}

wb_mesh_machine() {
  local host
  host="$(hostname 2>/dev/null || true)"
  printf '%s\n' "${host:-localhost}"
}

# A process's kernel start time (Linux clock ticks since boot), so a recycled
# pid is never mistaken for the session that recorded it. Empty off Linux.
wb_mesh_pid_start() {
  local pid="$1" stat
  [ -r "/proc/$pid/stat" ] || return 0
  stat="$(cat "/proc/$pid/stat" 2>/dev/null)" || return 0
  stat="${stat##*) }"
  # shellcheck disable=SC2086
  set -- $stat
  printf '%s\n' "${20:-}"
}

# One top-level string field of the account's settings.json.
wb_mesh_settings_field() {
  local key="$1" file
  file="$(wb_mesh_config_dir)/settings.json"
  [ -r "$file" ] || return 0
  if command -v python3 >/dev/null 2>&1; then
    python3 -I - "$file" "$key" <<'PY' 2>/dev/null && return 0
import json, sys
with open(sys.argv[1]) as f:
    value = json.load(f).get(sys.argv[2])
print(value if isinstance(value, str) else "")
PY
  fi
  sed -n "s/^[[:space:]]\{0,4\}\"$key\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$file" | head -n 1
}

# The model this session runs: $1 (the SessionStart hook input's `model`),
# then `--model` on the Claude process's command line, then the account's
# settings.json, else `unknown`. Sets WB_MESH_MODEL_SOURCE as a side effect.
wb_mesh_model() {
  local hook_model="${1:-}" pid="${2:-$(wb_mesh_claude_pid)}" model=""
  WB_MESH_MODEL_SOURCE="none"
  if [ -n "$hook_model" ]; then
    WB_MESH_MODEL_SOURCE="hook-input"; printf '%s\n' "$hook_model"; return 0
  fi
  if [ -n "$pid" ]; then
    model="$(wb_mesh_proc_args "$pid" | awk 'f { print; exit } $0 == "--model" { f = 1 } /^--model=/ { sub(/^--model=/, ""); print; exit }')"
    if [ -n "$model" ]; then WB_MESH_MODEL_SOURCE="cmdline"; printf '%s\n' "$model"; return 0; fi
  fi
  model="$(wb_mesh_settings_field model)"
  if [ -n "$model" ]; then WB_MESH_MODEL_SOURCE="settings"; printf '%s\n' "$model"; return 0; fi
  printf 'unknown\n'
}

wb_mesh_json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}

# This session's identity as one JSON object (the shape `who --json` rows use
# for the same fields).
wb_mesh_identity_json() {
  local explicit="${1:-}" pid actor account kind headless=false
  pid="$(wb_mesh_claude_pid)"
  actor="$(wb_mesh_actor "$explicit")"
  account="$(wb_mesh_account)"
  if [ -n "$pid" ] && wb_mesh_is_headless "$pid"; then headless=true; fi
  kind="${actor%%:*}"
  [ "$kind" != "$actor" ] || kind="actor"
  printf '{"actor":"%s","kind":"%s","account":"%s","name":"%s","session_id":"%s","machine":"%s","pid":%s,"headless":%s}\n' \
    "$(wb_mesh_json_escape "$actor")" "$(wb_mesh_json_escape "$kind")" \
    "$(wb_mesh_json_escape "$account")" "$(wb_mesh_json_escape "$(wb_mesh_name "$account")")" \
    "$(wb_mesh_json_escape "$(wb_mesh_session_id)")" "$(wb_mesh_json_escape "$(wb_mesh_machine)")" \
    "${pid:-null}" "$headless"
}

# Executed (not sourced): a small CLI over the functions above.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -u
  op="${1:-actor}"
  [ "$#" -gt 0 ] && shift
  explicit=""
  hook_model=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --as) explicit="${2:-}"; shift 2 || shift ;;
      --claude-pid) export WORKBENCH_MESH_CLAUDE_PID="${2:-}"; shift 2 || shift ;;
      --hook-model) hook_model="${2:-}"; shift 2 || shift ;;
      *) echo "mesh-identity: unknown argument: $1" >&2; exit 2 ;;
    esac
  done
  case "$op" in
    actor) wb_mesh_actor "$explicit" ;;
    account) wb_mesh_account ;;
    name) wb_mesh_name ;;
    session-id) wb_mesh_session_id ;;
    model) wb_mesh_model "$hook_model" ;;
    json) wb_mesh_identity_json "$explicit" ;;
    *) echo "usage: mesh-identity.sh actor|account|name|session-id|model|json [--as NAME] [--claude-pid PID] [--hook-model MODEL]" >&2; exit 2 ;;
  esac
fi
