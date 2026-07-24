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
  start [--local|--lan] [--bind local|lan] [--port N] [--pid-file PATH] [--as ACTOR]
  stop [--pid-file PATH]
  status | who | jobs | open
  invite [--role ROLE] [--ttl-seconds N] [--max-uses N]
  connect [HOST|URL] TOKEN [DEVICE] [--fingerprint sha256:HASH] [-y|--yes]
  devices
  revoke-device DEVICE
  room NAME [--as ACTOR]
  message TARGET TEXT... [--as ACTOR]
  ask TARGET QUESTION... [--as ACTOR]
  handoff TASK_ID TARGET [--as ACTOR]
  availability STATE [--reason TEXT] [--as ACTOR] [--platform NAME] [--capability VALUE]... [--provider NAME] [--model NAME]
  doing TEXT... [--as ACTOR] [--platform NAME] [--capability VALUE]... [--provider NAME] [--model NAME]
  watch ACTOR [--as ACTOR]
  tail --as ACTOR [--provider NAME] [--model NAME]   (reads stream-json on stdin)
  inbox --as ACTOR [--wait] [--since N]   (unread inbound messages; --wait blocks until one arrives)
  listen --as ACTOR         (starts the workbench-mesh listen connector in the foreground; run it backgrounded for listen-wait/inbox --wait to benefit from instant FIFO wake)
  listen-wait --as ACTOR   (blocks on the actor's FIFO, written by `workbench-mesh listen`; falls back to inbox --wait polling if no listen connector is running)
  activity reading|typing|idle [--as ACTOR]   (live engagement indicator on the dashboard)

--as ACTOR identifies this session/process as ACTOR in the posted event,
instead of the shared default "session:lead". Set this (or export
WORKBENCH_MESH_ACTOR) whenever more than one real session is expected to
post into the same room/mesh, so senders are distinguishable.

availability/doing auto-detect this session's OS (macos/linux/windows) and
its default dispatch capabilities (e.g. macOS gets ios-simulator). --platform
overrides auto-detection; --capability (repeatable) adds project-specific
extras on top. A lead reading these can route iOS QA only to macos sessions,
Windows-native work only to windows sessions, and so on.

tail pipes a live Claude/Codex session's stream-json into the mesh: it tees
stdin through to stdout unchanged while appending output.chunk events into the
room output:<ACTOR> and posting one presence heartbeat, so the actor appears on
the bench. --as is required (a tailer with no actor identity would write into
room "output:", which the server rejects). Example:
  claude -p "fix the bug" --output-format stream-json --verbose \
    | mesh.sh tail --as generator-1 --provider claude --model sonnet

start always writes a pid file so it can be stopped later — pass --pid-file
to choose the path explicitly (test harnesses do this), otherwise it defaults
to <target>/.workbench/mesh/server.pid, next to server.json. stop reads that
same default (or an explicit --pid-file) and sends SIGTERM, never SIGKILL.

start's --bind local|lan is equivalent to --local/--lan; any other value is
rejected before the success banner prints.
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
  # Only the lan_ips array — a bare number-dot grep over the whole file also
  # matches the host field and prints duplicate connect-ip lines.
  sed -n 's/.*"lan_ips"[[:space:]]*:[[:space:]]*\[\([^]]*\)\].*/\1/p' "$meta" \
    | tr ',' '\n' | sed -n 's/.*"\([0-9][0-9.]*\)".*/\1/p' | sort -u
}

print_connect_commands() {
  local token="$1" fingerprint="${2:-}" mode port host mdns ip url fp_flag
  port="$(metadata_port || true)"
  [ -n "$port" ] || return 0
  mode="$(metadata_field mode || true)"
  fp_flag=""
  [ -n "$fingerprint" ] && fp_flag=" --fingerprint sha256:$fingerprint"
  if [ "$mode" != "lan" ]; then
    if url="$(metadata_url)"; then
      printf 'connect-url: /workbench:mesh connect %s %s\n' "$url" "$token"
    fi
    return 0
  fi
  host="$(metadata_field hostname || true)"
  mdns="$(metadata_field mdns || true)"
  [ -n "$mdns" ] && printf 'connect: /workbench:mesh connect https://%s:%s %s%s\n' "$mdns" "$port" "$token" "$fp_flag"
  [ -n "$host" ] && [ "$host" != "$mdns" ] && printf 'connect-host: /workbench:mesh connect https://%s:%s %s%s\n' "$host" "$port" "$token" "$fp_flag"
  for ip in $(metadata_lan_ips || true); do
    [ -n "$ip" ] && printf 'connect-ip: /workbench:mesh connect %s %s%s\n' "$ip" "$token" "$fp_flag"
  done
  if url="$(metadata_url)"; then
    printf 'connect-url: /workbench:mesh connect %s %s%s\n' "$url" "$token" "$fp_flag"
  fi
}

print_start_info() {
  local mode="$1"
  local port="$2"
  if [ "$mode" = "lan" ]; then
    cat <<EOF
Workbench mesh will listen on the local network, over TLS.
Host: https://$(mdns_name):$port
LAN IP: https://$(lan_ip):$port
Local: https://127.0.0.1:$port
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

# Pull `--as ACTOR`, `--platform NAME`, repeatable `--capability VALUE`,
# `--provider NAME`, `--model NAME` out of the remaining args.
#
# message/ask/doing join their remaining args into UNBOUNDED free-text
# message/question/doing content, so for those three operations only, scan
# for these flags from the END of the argument list backward, stripping a
# trailing run of recognized `flag value` pairs — never from the middle.
# Every documented usage of these flags on these three ops has them trail
# the free text (e.g. `message TARGET TEXT... [--as ACTOR]`), so this means
# a flag-shaped word buried INSIDE a message (e.g. "please use --as flag
# correctly") is never mistaken for a real flag; only a genuine trailing
# flag (or a message whose literal last two words happen to collide) can
# still match — a much narrower window than the bug this replaces.
#
# Every other operation takes a bounded number of positional args plus
# these flags in any relative order (e.g. `inbox --as ACTOR --wait`, where
# --wait trails --as) — for those, front-to-back scanning is safe (there is
# no free-text tail to protect) and must be preserved, since a trailing-only
# scan would stop at --wait before ever reaching --as further left.
AS_ARGS=()
PLATFORM_ARGS=()
CAP_ARGS=()
PROVIDER_ARGS=()
MODEL_ARGS=()
case "$cmd" in
  message|ask|doing)
    if [ "$#" -gt 0 ]; then
      rest=("$@")
      while [ "${#rest[@]}" -ge 2 ]; do
        last=$((${#rest[@]} - 1))
        flag="${rest[$((last - 1))]}"
        value="${rest[$last]}"
        case "$flag" in
          --as) AS_ARGS=(--as "$value") ;;
          --platform) PLATFORM_ARGS=(--platform "$value") ;;
          --capability) CAP_ARGS=(--capability "$value" "${CAP_ARGS[@]}") ;;
          --provider) PROVIDER_ARGS=(--provider "$value") ;;
          --model) MODEL_ARGS=(--model "$value") ;;
          *) break ;;
        esac
        keep=$((${#rest[@]} - 2))
        if [ "$keep" -gt 0 ]; then
          rest=("${rest[@]:0:$keep}")
        else
          rest=()
        fi
      done
      set -- "${rest[@]}"
    fi
    ;;
  *)
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
          --provider)
            i=$((i + 1))
            PROVIDER_ARGS=(--provider "${!i:-}")
            ;;
          --model)
            i=$((i + 1))
            MODEL_ARGS=(--model "${!i:-}")
            ;;
          *)
            rest+=("$arg")
            ;;
        esac
        i=$((i + 1))
      done
      set -- "${rest[@]}"
    fi
    ;;
esac

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
          case "$2" in
            local|lan) mode="$2" ;;
            *) echo "mesh: --bind must be 'local' or 'lan' (got '$2')" >&2; exit 2 ;;
          esac
          shift 2
          ;;
        --port)
          require_arg "--port value" "${2:-}"
          port="$2"
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
    fi
    # Pass --port exactly once, computed from the fully-resolved $port (explicit
    # --port, or the lan-mode default above) — building this in two places
    # (inside the --port case above and again here) let `start --lan --port 0`
    # append --port twice, which clap rejects as a duplicate argument.
    pass+=(--port "$port")
    # Always record a pid file so `/workbench:mesh stop` can find and signal this
    # process later, even when the caller didn't ask for one explicitly — default to
    # a fixed path next to server.json rather than leaving the server unstoppable.
    [ -n "$pidfile" ] || pidfile="$TARGET/.workbench/mesh/server.pid"
    pass+=(--pid-file "$pidfile")
    "$BIN" auth bootstrap "${PROJECT_ARGS[@]}" >/dev/null
    print_start_info "$mode" "$port"
    exec "$BIN" serve "${PROJECT_ARGS[@]}" --bind "$mode" "${pass[@]}" "${AS_ARGS[@]}"
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
    if ! metadata_url >/dev/null 2>&1; then
      echo "mesh: no running mesh metadata found at $TARGET/.workbench/mesh/server.json" >&2
      echo "mesh: run /workbench:mesh start first" >&2
      exit 1
    fi
    exec "$BIN" status "${PROJECT_ARGS[@]}" "$@"
    ;;
  who)
    if ! metadata_url >/dev/null 2>&1; then
      echo "mesh: no running mesh metadata found at $TARGET/.workbench/mesh/server.json" >&2
      echo "mesh: run /workbench:mesh start first" >&2
      exit 1
    fi
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
      fingerprint="$(metadata_field tls_fingerprint || true)"
      if [ -n "$fingerprint" ]; then
        printf 'Fingerprint code: %s\n' "$("$BIN" fingerprint-code "$fingerprint")"
      fi
      [ -n "$token" ] && print_connect_commands "$token" "$fingerprint"
    else
      echo "url: start mesh first with /workbench:mesh start --lan to invite another machine"
    fi
    ;;
  connect)
    host_or_url=""
    if [ "${1:-}" != "" ] && printf '%s' "$1" | grep -Eq '^[A-Za-z0-9.-]+(:[0-9]+)?$|^https?://'; then
      host_or_url="$1"
      shift
    fi
    token="${1:-}"
    shift || true
    device="$(host_name)"
    extra=()
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --fingerprint) require_arg "--fingerprint value" "${2:-}"; extra+=(--fingerprint "$2"); shift 2 ;;
        -y|--yes) extra+=(--yes); shift ;;
        *) device="$1"; shift ;;
      esac
    done
    require_arg "invite token" "$token"
    if [ -n "$host_or_url" ]; then
      exec "$BIN" invite accept "${PROJECT_ARGS[@]}" --url "$host_or_url" --token "$token" --device "$device" "${extra[@]}"
    fi
    exec "$BIN" invite accept "${PROJECT_ARGS[@]}" --token "$token" --device "$device" "${extra[@]}"
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
    if ! metadata_url >/dev/null 2>&1; then
      echo "mesh: no running mesh metadata found at $TARGET/.workbench/mesh/server.json" >&2
      echo "mesh: run /workbench:mesh start first" >&2
      exit 1
    fi
    exec "$BIN" jobs "${PROJECT_ARGS[@]}" "$@"
    ;;
  availability)
    require_arg "availability state" "${1:-}"
    exec "$BIN" availability "${PROJECT_ARGS[@]}" "$@" "${AS_ARGS[@]}" "${PLATFORM_ARGS[@]}" "${CAP_ARGS[@]}" "${PROVIDER_ARGS[@]}" "${MODEL_ARGS[@]}"
    ;;
  doing)
    require_arg "doing text" "${1:-}"
    exec "$BIN" doing "${PROJECT_ARGS[@]}" "$*" "${AS_ARGS[@]}" "${PLATFORM_ARGS[@]}" "${CAP_ARGS[@]}" "${PROVIDER_ARGS[@]}" "${MODEL_ARGS[@]}"
    ;;
  watch)
    require_arg "actor" "${1:-}"
    exec "$BIN" watch "${PROJECT_ARGS[@]}" "$1" "${AS_ARGS[@]}"
    ;;
  activity)
    require_arg "activity state" "${1:-}"
    exec "$BIN" activity "${PROJECT_ARGS[@]}" "$@" "${AS_ARGS[@]}"
    ;;
  tail)
    # tail reads stream-json on stdin and needs an actor identity to name its
    # per-agent room output:<ACTOR>. Without --as it would write into "output:",
    # which the server rejects — fail early with a clear message instead.
    if [ "${#AS_ARGS[@]}" -eq 0 ] && [ -z "${WORKBENCH_MESH_ACTOR:-}" ]; then
      echo "mesh: tail requires --as ACTOR (or export WORKBENCH_MESH_ACTOR)" >&2
      usage >&2
      exit 2
    fi
    exec "$BIN" tail "${PROJECT_ARGS[@]}" "${AS_ARGS[@]}" "${PROVIDER_ARGS[@]}" "${MODEL_ARGS[@]}"
    ;;
  inbox)
    # Unread inbound messages for --as ACTOR: direct (to==actor), the actor's
    # own room, or shared rooms. --wait blocks until one arrives and then
    # exits — run it as a background task and its completion becomes a push
    # notification into the session (the harness re-invokes on completion).
    if [ "${#AS_ARGS[@]}" -eq 0 ] && [ -z "${WORKBENCH_MESH_ACTOR:-}" ]; then
      echo "mesh: inbox requires --as ACTOR (or export WORKBENCH_MESH_ACTOR)" >&2
      exit 2
    fi
    actor="${AS_ARGS[1]:-$WORKBENCH_MESH_ACTOR}"
    wait_flag=0
    since=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --wait) wait_flag=1; shift ;;
        --since) require_arg "--since value" "${2:-}"; since="$2"; shift 2 ;;
        *) echo "mesh: unknown arg to inbox: '$1'" >&2; exit 2 ;;
      esac
    done
    seq_file="$TARGET/.workbench/mesh/inbox-$actor.seq"
    [ -n "$since" ] || since="$(cat "$seq_file" 2>/dev/null || echo 0)"
    while true; do
      if ! bin_out="$("$BIN" event list "${PROJECT_ARGS[@]}" --since "$since" 2>&1)"; then
        echo "mesh: inbox failed for $actor: $bin_out" >&2
        exit 1
      fi
      out="$(printf '%s' "$bin_out" | ACTOR="$actor" python3 -c '
import json, os, sys
actor = os.environ["ACTOR"]
top, hits = 0, []
for line in sys.stdin:
    try:
        e = json.loads(line)
    except ValueError:
        continue
    top = max(top, e.get("seq", 0))
    if not e.get("type", "").startswith(("message.", "task.handoff")):
        continue
    if e.get("from") == actor:
        continue
    if e.get("to") == actor or e.get("room") in (actor, "team") or e.get("room", "").startswith("repo:"):
        p = e.get("payload", {})
        text = p.get("text") or p.get("task_id") or p.get("question") or "?"
        hits.append("seq=%s room=%s from=%s: %s" % (e["seq"], e["room"], e["from"], text))
print(top)
for h in hits:
    print(h)
')"
      top="$(printf '%s\n' "$out" | head -1)"
      body="$(printf '%s\n' "$out" | tail -n +2)"
      if [ -n "$body" ]; then
        printf '%s\n' "$top" > "$seq_file"
        printf 'mesh inbox for %s:\n%s\n' "$actor" "$body"
        exit 0
      fi
      case "$top" in ''|*[!0-9]*) : ;; *) [ "$top" -gt "$since" ] && { since="$top"; printf '%s\n' "$top" > "$seq_file"; } ;; esac
      [ "$wait_flag" = 1 ] || { echo "mesh inbox for $actor: empty"; exit 0; }
      sleep 2
    done
    ;;
  listen)
    # Starts the `workbench-mesh listen` connector in the foreground — the
    # process `listen-wait`'s FIFO fast path depends on. Run this as a
    # long-lived background task (nohup/tmux/&) for it to have any effect;
    # it blocks until killed.
    if [ "${#AS_ARGS[@]}" -eq 0 ] && [ -z "${WORKBENCH_MESH_ACTOR:-}" ]; then
      echo "mesh: listen requires --as ACTOR (or export WORKBENCH_MESH_ACTOR)" >&2
      exit 2
    fi
    exec "$BIN" listen "${PROJECT_ARGS[@]}" "${AS_ARGS[@]}" "$@"
    ;;
  listen-wait)
    # Blocks on the actor's per-actor FIFO written by a running
    # `workbench-mesh listen` connector — zero CPU cost, instant wake.
    # Falls back to polling `inbox --wait` if no connector is running
    # (i.e. the FIFO does not exist yet).
    if [ "${#AS_ARGS[@]}" -eq 0 ] && [ -z "${WORKBENCH_MESH_ACTOR:-}" ]; then
      echo "mesh: listen-wait requires --as ACTOR (or export WORKBENCH_MESH_ACTOR)" >&2
      exit 2
    fi
    actor="${AS_ARGS[1]:-$WORKBENCH_MESH_ACTOR}"
    safe_actor="$(printf '%s' "$actor" | tr ':/' '--')"
    fifo="$TARGET/.workbench/mesh/inbox-$safe_actor.fifo"
    if [ -p "$fifo" ]; then
      # Blocking read on a FIFO costs zero CPU while idle and wakes the
      # instant `workbench-mesh listen` writes a line — no polling interval
      # to tune, no latency floor.
      line="$(head -n 1 "$fifo")"
      printf 'mesh inbox for %s:\n%s\n' "$actor" "$line"
      exit 0
    fi
    echo "mesh: no listen connector running for $actor (missing $fifo) — falling back to polling inbox --wait" >&2
    exec "$0" inbox --as "$actor" --wait
    ;;
  open)
    if url="$(metadata_url)"; then
      token="$(metadata_field local_token)"
      if [ -n "$token" ]; then
        printf 'Command center: %s/?token=%s\n' "$url" "$token"
      else
        printf 'Command center: %s\n' "$url"
        echo "mesh: no local_token found in $TARGET/.workbench/mesh/server.json — the server may need a restart"
      fi
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
