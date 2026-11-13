#!/usr/bin/env bash
# Session presence on the project's Workbench mesh, driven by the session
# lifecycle hooks — no manual `availability` call:
#   SessionStart      join: actor + account + model + provider + advisor, and
#                     export WORKBENCH_MESH_{ACTOR,PROVIDER,MODEL} for the
#                     session's Bash tool through CLAUDE_ENV_FILE
#   UserPromptSubmit  busy
#   PostToolUse       heartbeat (at most one per WORKBENCH_MESH_BEAT_SECS)
#   Stop              idle
#   SessionEnd        leave (the roster drops the session at once)
#
# Never blocks or fails the session: no mesh in this project -> exit 0; the
# post runs in the background under a timeout; nothing is written to stdout
# (stdout would land in the model's context). Never logs a token: the log
# holds the event name, actor, model source and the post's exit status.
# Opt out with WORKBENCH_MESH_PRESENCE=off.
set -u

[ "${WORKBENCH_MESH_PRESENCE:-on}" = "off" ] && exit 0
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT="${CLAUDE_PROJECT_DIR:-$PWD}"
MESH_DIR="$PROJECT/.workbench/mesh"
[ -f "$MESH_DIR/server.json" ] || exit 0
# shellcheck source=scripts/mesh-identity.sh
. "$SELF_DIR/../../scripts/mesh-identity.sh" 2>/dev/null || exit 0
MESH_SH="$SELF_DIR/../../scripts/mesh.sh"
[ -f "$MESH_SH" ] || exit 0
umask 077

input="$(cat 2>/dev/null || true)"
field() { # one flat string field of the hook input
  printf '%s' "$input" | tr -d '\n' | sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -n 1
}
event="$(field hook_event_name)"
[ -n "$event" ] || exit 0

claude_pid="$(wb_mesh_claude_pid)"
sid="$(wb_mesh_session_id "$(field session_id)")"
[ -n "$sid" ] || sid="pid-${claude_pid:-$PPID}"
mkdir -p "$MESH_DIR/sessions" 2>/dev/null || exit 0
STATE="$MESH_DIR/sessions/$sid"
LOG="$MESH_DIR/presence-hook.log"

state_get() { [ -f "$STATE" ] && sed -n "s/^$1=//p" "$STATE" | head -n 1; }
log() {
  printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" >> "$LOG" 2>/dev/null || true
  # Keep the log small; it is a debugging aid, not a record.
  if [ "$(wc -l < "$LOG" 2>/dev/null || echo 0)" -gt 400 ]; then
    tail -n 200 "$LOG" > "$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG"
  fi
}
run_bounded() { # run_bounded <seconds> <command...>
  local secs="$1"; shift
  if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"; else "$@"; fi
}
mesh() { CLAUDE_PROJECT_DIR="$PROJECT" run_bounded "$1" bash "$MESH_SH" "${@:2}" </dev/null >/dev/null 2>&1; }

if [ "$event" = "SessionEnd" ]; then
  actor="$(state_get actor)"
  [ -n "$actor" ] || actor="$(wb_mesh_actor)"
  # Foreground and short: the process is on its way out.
  mesh 3 leave --as "$actor" --session-id "$sid"
  log "event=SessionEnd actor=$actor rc=$?"
  rm -f "$STATE" "$STATE.mirror"
  exit 0
fi

# Identity is detected once per session and cached; later events (whose input
# carries no model) reuse it. A session that predates the mesh joins lazily on
# its next event.
actor="$(state_get actor)"
if [ "$event" = "SessionStart" ] || [ -z "$actor" ]; then
  actor="$(wb_mesh_actor)"
  wb_mesh_model "$(field model)" "$claude_pid" >/dev/null
  model="$WB_MESH_MODEL"; model_src="$WB_MESH_MODEL_SOURCE"
  advisor="$(wb_mesh_settings_field advisorModel)"
  account="$(wb_mesh_account)"
  headless=0
  if [ -n "$claude_pid" ] && wb_mesh_is_headless "$claude_pid"; then headless=1; fi
  pid_start=""
  [ -z "$claude_pid" ] || pid_start="$(wb_mesh_pid_start "$claude_pid")"
  joined=1
else
  model="$(state_get model)"; advisor="$(state_get advisor)"; account="$(state_get account)"
  headless="$(state_get headless)"; pid_start="$(state_get pid_start)"
  [ -n "$claude_pid" ] || claude_pid="$(state_get pid)"
  joined=0
fi
[ -n "$model" ] || model="unknown"
[ -n "$headless" ] || headless=0

prev_activity="$(state_get activity)"
last_beat="$(state_get beat)"
case "$last_beat" in ''|*[!0-9]*) last_beat=0 ;; esac
now="$(date +%s)"
case "$event" in
  UserPromptSubmit) activity="busy" ;;
  Stop) activity="idle" ;;
  SessionStart) if [ "$headless" = 1 ]; then activity="busy"; else activity="idle"; fi ;;
  PostToolUse) activity="busy" ;;   # a tool just ran: the session is mid-turn
  *) activity="${prev_activity:-busy}" ;;
esac
# A headless lane works from start to finish.
[ "$headless" = 1 ] && activity="busy"

beat_every="${WORKBENCH_MESH_BEAT_SECS:-300}"
case "$beat_every" in ''|*[!0-9]*) beat_every=300 ;; esac
post=0
if [ "$joined" = 1 ] || [ "$activity" != "$prev_activity" ] || [ $((now - last_beat)) -ge "$beat_every" ]; then
  post=1
fi

write_state() {
  {
    printf 'actor=%s\n' "$actor"
    printf 'account=%s\n' "$account"
    printf 'model=%s\n' "$model"
    printf 'advisor=%s\n' "$advisor"
    printf 'provider=claude\n'
    printf 'headless=%s\n' "$headless"
    printf 'pid=%s\n' "$claude_pid"
    printf 'pid_start=%s\n' "$pid_start"
    printf 'machine=%s\n' "$(wb_mesh_machine)"
    printf 'activity=%s\n' "$activity"
    printf 'beat=%s\n' "$1"
  } > "$STATE.tmp" 2>/dev/null && mv "$STATE.tmp" "$STATE"
}

if [ "$event" = "SessionStart" ] && [ -n "${CLAUDE_ENV_FILE:-}" ]; then
  # Verified on Claude Code 2.1.323: lines appended here are sourced before
  # every Bash tool command of this session. The OWNER pid stops a nested
  # `claude -p` (which inherits these) from posting under this session's name.
  {
    printf 'export WORKBENCH_MESH_ACTOR=%q\n' "$actor"
    printf 'export WORKBENCH_MESH_ACTOR_OWNER=%q\n' "$claude_pid"
    printf 'export WORKBENCH_MESH_PROVIDER=claude\n'
    printf 'export WORKBENCH_MESH_MODEL=%q\n' "$model"
    printf 'export WORKBENCH_MESH_SESSION_ID=%q\n' "$sid"
  } >> "$CLAUDE_ENV_FILE" 2>/dev/null || true
fi

if [ "$post" != 1 ]; then
  exit 0
fi
write_state "$now"

availability="available"
[ "$activity" = "busy" ] && availability="busy"
args=(availability "$availability" --as "$actor" --provider claude --model "$model"
  --session-id "$sid" --account "$account" --machine "$(wb_mesh_machine)" --activity "$activity")
[ -z "$claude_pid" ] || args+=(--pid "$claude_pid")
[ -z "$pid_start" ] || args+=(--pid-start "$pid_start")
[ "$headless" = 1 ] && args+=(--reason "headless lane")
[ -z "$advisor" ] || args+=(--capability "advisor:$advisor")

post_beat() {
  mesh 10 "${args[@]}"
  rc=$?
  if [ "$joined" = 1 ] || [ "$rc" != 0 ]; then
    log "event=$event actor=$actor model_src=${model_src:-cached} headless=$headless activity=$activity envfile=${CLAUDE_ENV_FILE:+yes} rc=$rc"
  fi
}
if [ "${WORKBENCH_MESH_HOOK_WAIT:-0}" = 1 ]; then
  post_beat
else
  ( post_beat ) </dev/null >/dev/null 2>&1 &
  disown 2>/dev/null || true
fi
exit 0
