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
  stop [--pid-file PATH]
  status | who | jobs | open
  invite [--role ROLE] [--ttl-seconds N] [--max-uses N]
  connect [URL] TOKEN [DEVICE]
  devices
  revoke-device DEVICE
  room NAME [--as ACTOR]
  message TARGET TEXT... [--as ACTOR]
  ask TARGET QUESTION... [--as ACTOR]
  handoff TASK_ID TARGET [--as ACTOR]
  availability STATE [--reason TEXT] [--as ACTOR] [--platform NAME] [--capability VALUE]...
  doing TEXT... [--as ACTOR] [--platform NAME] [--capability VALUE]...
  watch ACTOR [--as ACTOR]

--as ACTOR identifies this session/process as ACTOR in the posted event,
instead of the shared default "session:lead". Set this (or export
WORKBENCH_MESH_ACTOR) whenever more than one real session is expected to
post into the same room/mesh, so senders are distinguishable.

availability/doing auto-detect this session's OS (macos/linux/windows) and
its default dispatch capabilities (e.g. macOS gets ios-simulator). --platform
overrides auto-detection; --capability (repeatable) adds project-specific
extras on top. A lead reading these can route iOS QA only to macos sessions,
Windows-native work only to windows sessions, and so on.

start always writes a pid file so it can be stopped later — pass --pid-file
to choose the path explicitly (test harnesses do this), otherwise it defaults
to <target>/.workbench/mesh/server.pid, next to server.json. stop reads that
same default (or an explicit --pid-file) and sends SIGTERM, never SIGKILL.
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
  local token="$1" mode port host mdns ip url
  port="$(metadata_port || true)"
  [ -n "$port" ] || return 0
  mode="$(metadata_field mode || true)"
  if [ "$mode" != "lan" ]; then
    if url="$(metadata_url)"; then
      printf 'connect-url: /workbench:mesh connect %s %s <device>\n' "$url" "$token"
    fi
    return 0
  fi
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

# Pull `--as ACTOR`, `--platform NAME`, and repeatable `--capability VALUE`
# out of the remaining args, wherever they appear, so they don't get
# swallowed by commands that greedily join the rest of the args as
# message/question/doing text (e.g. `doing "fixing tests" --platform macos`).
# Leaves the *_ARGS arrays empty (nothing passed to the binary) when the
# corresponding flag wasn't given, so the binary's own auto-detection
# (WORKBENCH_MESH_ACTOR / std::env::consts::OS) still applies.
AS_ARGS=()
PLATFORM_ARGS=()
CAP_ARGS=()
if [ "$#" -gt 0 ]; then
  rest=()
  i=1
  while [ "$i" -le "$#" ]; do
    arg="${!i}"
    case "$arg" in
      --as)
        i=$((i + 1))
        AS_ARGS=(--as "${!i:-}")
        ;;
      --platform)
        i=$((i + 1))
        PLATFORM_ARGS=(--platform "${!i:-}")
        ;;
      --capability)
        i=$((i + 1))
        CAP_ARGS+=(--capability "${!i:-}")
        ;;
      *)
        rest+=("$arg")
        ;;
    esac
    i=$((i + 1))
  done
  set -- "${rest[@]}"
fi

case "$cmd" in
  start)
    mode="local"
    port="0"
    pidfile=""
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
        --pid-file)
          require_arg "--pid-file value" "${2:-}"
          pidfile="$2"
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
    # Always record a pid file so `/workbench:mesh stop` can find and signal this
    # process later, even when the caller didn't ask for one explicitly — default to
    # a fixed path next to server.json rather than leaving the server unstoppable.
    [ -n "$pidfile" ] || pidfile="$TARGET/.workbench/mesh/server.pid"
    pass+=(--pid-file "$pidfile")
    "$BIN" auth bootstrap "${PROJECT_ARGS[@]}" >/dev/null
    print_start_info "$mode" "$port"
    exec "$BIN" serve "${PROJECT_ARGS[@]}" --bind "$mode" "${pass[@]}"
    ;;
  stop)
    pidfile=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --pid-file)
          require_arg "--pid-file value" "${2:-}"
          pidfile="$2"
          shift 2
          ;;
        *)
          echo "mesh: unknown arg to stop: '$1'" >&2
          usage >&2
          exit 2
          ;;
      esac
    done
    [ -n "$pidfile" ] || pidfile="$TARGET/.workbench/mesh/server.pid"
    if [ ! -f "$pidfile" ]; then
      echo "mesh: no pid file at $pidfile — is a mesh server running? (start with /workbench:mesh start)" >&2
      exit 1
    fi
    pid="$(tr -d ' \t\n' < "$pidfile")"
    case "$pid" in
      ''|*[!0-9]*)
        echo "mesh: pid file $pidfile does not contain a valid pid ('$pid')" >&2
        exit 1
        ;;
    esac
    if ! kill -0 "$pid" 2>/dev/null; then
      echo "mesh: process $pid (from $pidfile) is not running — removing stale pid file"
      rm -f "$pidfile"
      exit 0
    fi
    if ! kill -TERM "$pid" 2>/dev/null; then
      echo "mesh: failed to signal pid $pid" >&2
      exit 1
    fi
    for _ in $(seq 1 50); do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.1
    done
    if kill -0 "$pid" 2>/dev/null; then
      echo "mesh: sent SIGTERM to $pid but it is still running after 5s" >&2
      exit 1
    fi
    rm -f "$pidfile"
    echo "mesh: stopped mesh server (pid $pid)"
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
    exec "$BIN" room create "${PROJECT_ARGS[@]}" --name "$1" "${AS_ARGS[@]}"
    ;;
  message)
    require_arg "message target" "${1:-}"
    to="$1"
    shift
    require_arg "message text" "${1:-}"
    exec "$BIN" message "${PROJECT_ARGS[@]}" --to "$to" --text "$*" "${AS_ARGS[@]}"
    ;;
  ask)
    require_arg "ask target" "${1:-}"
    to="$1"
    shift
    require_arg "question" "${1:-}"
    exec "$BIN" ask "${PROJECT_ARGS[@]}" --to "$to" --question "$*" "${AS_ARGS[@]}"
    ;;
  handoff)
    require_arg "task id" "${1:-}"
    task_id="$1"
    require_arg "handoff target" "${2:-}"
    exec "$BIN" handoff "${PROJECT_ARGS[@]}" --task-id "$task_id" --to "$2" "${AS_ARGS[@]}"
    ;;
  jobs)
    if [ -x "$PLUGIN_ROOT/scripts/job.sh" ]; then
      job_out="$(bash "$PLUGIN_ROOT/scripts/job.sh" list --active --target "$TARGET" 2>/dev/null || true)"
      if [ -n "$job_out" ]; then
        printf 'Workbench jobs:\n'
        printf '%s\n' "$job_out" | while IFS=$'\t' read -r job_id job_type task_id job_status job_summary; do
          [ -n "$job_id" ] || continue
          printf '  %s  %s  task:%s  %s\n' "$job_id" "$job_status" "$task_id" "$job_summary"
        done
        exit 0
      fi
    fi
    exec "$BIN" jobs "${PROJECT_ARGS[@]}" "$@"
    ;;
  availability)
    require_arg "availability state" "${1:-}"
    exec "$BIN" availability "${PROJECT_ARGS[@]}" "$@" "${AS_ARGS[@]}" "${PLATFORM_ARGS[@]}" "${CAP_ARGS[@]}"
    ;;
  doing)
    require_arg "doing text" "${1:-}"
    exec "$BIN" doing "${PROJECT_ARGS[@]}" "$*" "${AS_ARGS[@]}" "${PLATFORM_ARGS[@]}" "${CAP_ARGS[@]}"
    ;;
  watch)
    require_arg "actor" "${1:-}"
    exec "$BIN" watch "${PROJECT_ARGS[@]}" "$1" "${AS_ARGS[@]}"
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
