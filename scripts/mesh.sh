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
  devices
  revoke-device DEVICE
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

metadata_field() {
  local key="$1" meta="$TARGET/.workbench/mesh/server.json"
  [ -f "$meta" ] || return 1
  sed -n "s/.*\"$key\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$meta" | head -1
}

metadata_port() {
  local meta="$TARGET/.workbench/mesh/server.json"
  [ -f "$meta" ] || return 1
  sed -n 's/.*"port"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$meta" | head -1
}

metadata_lan_ips() {
  local meta="$TARGET/.workbench/mesh/server.json"
  [ -f "$meta" ] || return 1
  tr ',' '\n' < "$meta" | sed -n 's/.*"\([0-9][0-9.]*\)".*/\1/p'
}

print_connect_commands() {
  local token="$1" port host mdns ip url
  port="$(metadata_port || true)"
  [ -n "$port" ] || return 0
  host="$(metadata_field hostname || true)"
  mdns="$(metadata_field mdns || true)"
  [ -n "$mdns" ] && printf 'connect: /workbench:mesh connect http://%s:%s %s <device>\n' "$mdns" "$port" "$token"
  [ -n "$host" ] && [ "$host" != "$mdns" ] && printf 'connect-host: /workbench:mesh connect http://%s:%s %s <device>\n' "$host" "$port" "$token"
  for ip in $(metadata_lan_ips || true); do
    [ -n "$ip" ] && printf 'connect-ip: /workbench:mesh connect http://%s:%s %s <device>\n' "$ip" "$port" "$token"
  done
  if url="$(metadata_url)"; then
    printf 'connect-url: /workbench:mesh connect %s %s <device>\n' "$url" "$token"
  fi
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
    if [ "$port" = "0" ]; then
      cat <<EOF
Workbench mesh will listen on this machine only.
Command center: URL will be written to $TARGET/.workbench/mesh/server.json after startup.
Public internet: unavailable in this version.
EOF
    else
      cat <<EOF
Workbench mesh will listen on this machine only.
Command center: http://127.0.0.1:$port
Public internet: unavailable in this version.
EOF
    fi
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
      invite_out="$("$BIN" invite create "${PROJECT_ARGS[@]}" "$@")"
    else
      invite_out="$("$BIN" invite create "${PROJECT_ARGS[@]}" --role worker "$@")"
    fi
    printf '%s\n' "$invite_out"
    token="$(printf '%s\n' "$invite_out" | sed -n 's/^token: //p' | head -1)"
    if url="$(metadata_url)"; then
      printf 'url: %s\n' "$url"
      [ -n "$token" ] && print_connect_commands "$token"
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
    if [ -n "$url" ]; then
      exec "$BIN" invite accept "${PROJECT_ARGS[@]}" --url "$url" --token "$token" --device "$device"
    fi
    exec "$BIN" invite accept "${PROJECT_ARGS[@]}" --token "$token" --device "$device"
    ;;
  devices)
    exec "$BIN" device list "${PROJECT_ARGS[@]}" "$@"
    ;;
  revoke-device)
    require_arg "device" "${1:-}"
    exec "$BIN" device revoke "${PROJECT_ARGS[@]}" --device "$1"
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
    exec "$BIN" jobs "${PROJECT_ARGS[@]}" "$@"
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
      echo "Open the command center in a browser and use a local project credential token when prompted."
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
