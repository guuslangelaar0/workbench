#!/usr/bin/env bash
set -euo pipefail

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
BIN="$PLUGIN_ROOT/bin/workbench-mesh"
TARGET="${CLAUDE_PROJECT_DIR:-$PWD}"

if [ ! -x "$BIN" ]; then
  echo "mesh: missing executable $BIN" >&2
  echo "mesh: run cargo build -p workbench-mesh --release or install a packaged binary" >&2
  exit 69
fi

PROJECT_ARGS=(--target "$TARGET")
if [ -n "${WORKBENCH_HOME:-}" ]; then
  PROJECT_ARGS+=(--home "$WORKBENCH_HOME")
fi

usage() {
  cat <<'EOF'
usage: mesh.sh <operation> [args]

operations:
  start [--local|--lan] [--port N] [--pid-file PATH]
  status | who | jobs | open
  invite [--role ROLE] [--ttl-seconds N] [--max-uses N]
  connect [URL] TOKEN [DEVICE]
  room NAME
  message TARGET TEXT...
  ask TARGET QUESTION...
  handoff TASK_ID TARGET
  availability STATE [--reason TEXT]
  doing TEXT...
  watch ACTOR
EOF
}

host_name() {
  hostname 2>/dev/null || printf 'localhost'
}

mdns_name() {
  local host
  host="$(host_name | tr ' ' '-')"
  case "$host" in
    *.local) printf '%s\n' "$host" ;;
    *) printf '%s.local\n' "$host" ;;
  esac
}

lan_ip() {
  if command -v ipconfig >/dev/null 2>&1; then
    ipconfig getifaddr en0 2>/dev/null && return 0
    ipconfig getifaddr en1 2>/dev/null && return 0
  fi
  if command -v hostname >/dev/null 2>&1; then
    hostname -I 2>/dev/null | awk '{print $1}' && return 0
  fi
  if command -v ip >/dev/null 2>&1; then
    ip route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([^ ]*\).*/\1/p' | head -1 && return 0
  fi
  printf 'unknown'
}

metadata_url() {
  local meta host port
  meta="$TARGET/.workbench/mesh/server.json"
  [ -f "$meta" ] || return 1
  host="$(sed -n 's/.*"host"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$meta" | head -1)"
  port="$(sed -n 's/.*"port"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$meta" | head -1)"
  [ -n "$host" ] && [ -n "$port" ] || return 1
  printf 'http://%s:%s\n' "$host" "$port"
}

print_start_info() {
  local mode="$1"
  local port="$2"
  if [ "$mode" = "lan" ]; then
    cat <<EOF
Workbench mesh will listen on the local network.
Host: $(mdns_name):$port
LAN IP: $(lan_ip):$port
Local: 127.0.0.1:$port
Command center: http://127.0.0.1:$port
Invite: run /workbench:mesh invite --role worker --ttl-seconds 900
Public internet: unavailable in this version.
EOF
  else
    cat <<EOF
Workbench mesh will listen on this machine only.
Command center: http://127.0.0.1:$port
Public internet: unavailable in this version.
EOF
  fi
}

require_arg() {
  local name="$1"
  local value="${2:-}"
  if [ -z "$value" ]; then
    echo "mesh: missing $name" >&2
    usage >&2
    exit 2
  fi
}

cmd="${1:-}"
[ -n "$cmd" ] || { usage; exit 2; }
shift || true

case "$cmd" in
  start)
    mode="local"
    port="0"
    pass=()
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --lan)
          mode="lan"
          shift
          ;;
        --local)
          mode="local"
          shift
          ;;
        --bind)
          require_arg "--bind value" "${2:-}"
          mode="$2"
          shift 2
          ;;
        --port)
          require_arg "--port value" "${2:-}"
          port="$2"
          pass+=(--port "$2")
          shift 2
          ;;
        *)
          pass+=("$1")
          shift
          ;;
      esac
    done
    if [ "$mode" = "lan" ] && [ "$port" = "0" ]; then
      port="${WORKBENCH_MESH_PORT:-47321}"
      pass+=(--port "$port")
    fi
    "$BIN" auth bootstrap "${PROJECT_ARGS[@]}" >/dev/null
    print_start_info "$mode" "$port"
    exec "$BIN" serve "${PROJECT_ARGS[@]}" --bind "$mode" "${pass[@]}"
    ;;
  status)
    exec "$BIN" status "${PROJECT_ARGS[@]}" "$@"
    ;;
  who)
    exec "$BIN" who "${PROJECT_ARGS[@]}" "$@"
    ;;
  invite)
    has_role=0
    for arg in "$@"; do
      [ "$arg" = "--role" ] && has_role=1
    done
    if [ "$has_role" = 1 ]; then
      "$BIN" invite create "${PROJECT_ARGS[@]}" "$@"
    else
      "$BIN" invite create "${PROJECT_ARGS[@]}" --role worker "$@"
    fi
    if url="$(metadata_url)"; then
      printf 'url: %s\n' "$url"
    else
      echo "url: start mesh first with /workbench:mesh start --lan to invite another machine"
    fi
    ;;
  connect)
    url=""
    if [ "${1:-}" != "" ] && printf '%s' "$1" | grep -Eq '^https?://'; then
      url="$1"
      shift
    fi
    token="${1:-}"
    device="${2:-$(host_name)}"
    require_arg "invite token" "$token"
    [ -z "$url" ] || printf 'connecting to: %s\n' "$url"
    exec "$BIN" invite accept "${PROJECT_ARGS[@]}" --token "$token" --device "$device"
    ;;
  room)
    require_arg "room name" "${1:-}"
    exec "$BIN" room create "${PROJECT_ARGS[@]}" --name "$1"
    ;;
  message)
    require_arg "message target" "${1:-}"
    to="$1"
    shift
    require_arg "message text" "${1:-}"
    exec "$BIN" message "${PROJECT_ARGS[@]}" --to "$to" --text "$*"
    ;;
  ask)
    require_arg "ask target" "${1:-}"
    to="$1"
    shift
    require_arg "question" "${1:-}"
    exec "$BIN" ask "${PROJECT_ARGS[@]}" --to "$to" --question "$*"
    ;;
  handoff)
    require_arg "task id" "${1:-}"
    task_id="$1"
    require_arg "handoff target" "${2:-}"
    exec "$BIN" handoff "${PROJECT_ARGS[@]}" --task-id "$task_id" --to "$2"
    ;;
  jobs)
    "$BIN" event list "${PROJECT_ARGS[@]}" --since 0 "$@" | grep '"type":"job\.' || true
    ;;
  availability)
    require_arg "availability state" "${1:-}"
    exec "$BIN" availability "${PROJECT_ARGS[@]}" "$@"
    ;;
  doing)
    require_arg "doing text" "${1:-}"
    exec "$BIN" doing "${PROJECT_ARGS[@]}" "$*"
    ;;
  watch)
    require_arg "actor" "${1:-}"
    exec "$BIN" watch "${PROJECT_ARGS[@]}" "$1"
    ;;
  open)
    if url="$(metadata_url)"; then
      printf 'Command center: %s\n' "$url"
      echo "Command center UI is added in a later task; the mesh API is available at this URL now."
    else
      echo "mesh: no running mesh metadata found at $TARGET/.workbench/mesh/server.json" >&2
      echo "mesh: run /workbench:mesh start first" >&2
      exit 1
    fi
    ;;
  help|-h|--help)
    usage
    ;;
  *)
    echo "mesh: unknown operation: $cmd" >&2
    usage >&2
    exit 2
    ;;
esac
