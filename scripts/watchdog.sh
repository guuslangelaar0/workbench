#!/usr/bin/env bash
# workbench EXTERNAL watchdog — relaunches a hard-crashed /workbench:loop.
#
# This is NOT a Claude Code hook. A StopFailure hook (hooks/bin/stopfailure-recover.sh)
# can only leave a breadcrumb; it cannot resume the session, and in-session
# ScheduleWakeup crons die with the session. So self-heal after a hard crash (API
# error, Anthropic outage, process death) needs an OUT-OF-PROCESS supervisor — this
# script — driven by cron or a systemd timer.
#
# It relaunches the loop when EITHER:
#   (a) a recovery marker ($(il_cfg_dir)/recovery/last-failure) exists and is NEWER
#       than the last resume we performed (a StopFailure happened since), OR
#   (b) <project>/.claude/SESSION_STATE.md is STALE — mtime older than --max-idle
#       (or missing entirely) — i.e. the loop appears to have stopped checkpointing.
#
# By DEFAULT it is a DRY-RUN: it only prints the command it would run plus a one-line
# reason. Pass --exec to actually relaunch. After a successful resume it touches a
# last-resume stamp so it doesn't thrash on the same failure.
#
# Usage:
#   scripts/watchdog.sh --session-id ID [--project DIR] [--max-idle SECS] [--exec]
#
#   --session-id ID   (required) the Claude Code session to `claude --resume`
#   --project DIR     project root (default: $PWD)
#   --max-idle SECS   SESSION_STATE.md older than this ⇒ stale ⇒ resume (default: 1800)
#   --exec            actually run the resume command (default: dry-run / print only)
#   -h, --help        show this help
#
# Example crontab (every 5 minutes, execute, log output):
#   */5 * * * * /path/to/workbench/scripts/watchdog.sh \
#       --session-id abc123 --project /home/me/proj --max-idle 1800 --exec \
#       >> /home/me/proj/.workbench/recovery/watchdog.log 2>&1
#
# Example systemd (user) units — watchdog.service + watchdog.timer:
#   # ~/.config/systemd/user/wb-watchdog.service
#   [Unit]
#   Description=workbench loop watchdog
#   [Service]
#   Type=oneshot
#   ExecStart=/path/to/workbench/scripts/watchdog.sh --session-id abc123 \
#       --project /home/me/proj --max-idle 1800 --exec
#
#   # ~/.config/systemd/user/wb-watchdog.timer
#   [Unit]
#   Description=run workbench watchdog every 5 minutes
#   [Timer]
#   OnBootSec=2min
#   OnUnitActiveSec=5min
#   [Install]
#   WantedBy=timers.target
#   # then: systemctl --user enable --now wb-watchdog.timer
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SELF_DIR/lib.sh"

SESSION_ID=""
PROJECT="$PWD"
MAX_IDLE=1800
EXEC=0

usage() { sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --session-id) SESSION_ID="${2:-}"; shift 2 ;;
    --project)    PROJECT="${2:-$PWD}"; shift 2 ;;
    --max-idle)   MAX_IDLE="${2:-1800}"; shift 2 ;;
    --exec)       EXEC=1; shift ;;
    -h|--help)    usage; exit 0 ;;
    *) echo "watchdog: unknown argument '$1'" >&2; usage; exit 2 ;;
  esac
done

[ -n "$SESSION_ID" ] || { echo "watchdog: --session-id is required" >&2; usage; exit 2; }

CFG="$(il_cfg_dir "$PROJECT")"
REC_DIR="$CFG/recovery"
MARKER="$REC_DIR/last-failure"
STAMP="$REC_DIR/last-resume"
STATE="$PROJECT/.claude/SESSION_STATE.md"

now="${EPOCHSECONDS:-}"
[ -n "$now" ] || now="$(date +%s 2>/dev/null || echo 0)"

# mtime of a file in epoch seconds, or empty if absent/unreadable. GNU stat first,
# BSD/macOS stat second, then a portable date fallback.
mtime() { # <path>
  [ -e "$1" ] || return 0
  stat -c %Y "$1" 2>/dev/null && return 0
  stat -f %m "$1" 2>/dev/null && return 0
  date -r "$1" +%s 2>/dev/null || true
}

reason=""

# (a) recovery marker newer than the last resume → a StopFailure happened since.
m_marker="$(mtime "$MARKER")"
m_stamp="$(mtime "$STAMP")"
if [ -n "$m_marker" ]; then
  cat=""
  cat="$(sed -n '2p' "$MARKER" 2>/dev/null || true)"
  if [ -z "$m_stamp" ] || [ "$m_marker" -gt "$m_stamp" ]; then
    reason="recovery marker present (${cat:-unknown}) and newer than last resume"
  fi
fi

# (b) SESSION_STATE.md stale or missing → the loop stopped checkpointing.
if [ -z "$reason" ]; then
  m_state="$(mtime "$STATE")"
  if [ -z "$m_state" ]; then
    reason="SESSION_STATE.md missing — loop never checkpointed or was wiped"
  else
    age=$(( now - m_state ))
    if [ "$age" -gt "$MAX_IDLE" ]; then
      reason="SESSION_STATE.md stale (${age}s old > --max-idle ${MAX_IDLE}s)"
    fi
  fi
fi

RESUME_PROMPT="Recover the workbench loop. Read .workbench/loop-charter.md and .claude/SESSION_STATE.md, then continue /workbench:loop."

if [ -z "$reason" ]; then
  echo "loop healthy — no resume needed (session ${SESSION_ID})"
  exit 0
fi

# Build the resume command as an array so it executes safely with spaces.
set -- claude --resume "$SESSION_ID" -p "$RESUME_PROMPT"

if [ "$EXEC" = 1 ]; then
  echo "watchdog: resuming — $reason"
  echo "+ claude --resume \"$SESSION_ID\" -p \"$RESUME_PROMPT\""
  if "$@"; then
    mkdir -p "$REC_DIR" 2>/dev/null || true
    : > "$STAMP" 2>/dev/null || true   # touch last-resume stamp to avoid thrashing
    echo "watchdog: resume command exited 0; stamped $STAMP"
    exit 0
  else
    rc=$?
    echo "watchdog: resume command failed (exit $rc)" >&2
    exit "$rc"
  fi
else
  echo "DRY-RUN: would resume — $reason"
  echo "claude --resume \"$SESSION_ID\" -p \"$RESUME_PROMPT\""
  echo "(pass --exec to actually relaunch)"
  exit 0
fi
