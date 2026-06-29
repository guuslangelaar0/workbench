#!/usr/bin/env bash
# workbench: file-based liveness LEASE for dispatched lanes. The orchestration lead
# judges whether a dispatched engineer/verifier lane is alive by a heartbeat ON DISK
# — NOT by trusting the in-memory team registry, which goes stale after an API error
# or resume (the "phantom teammate" problem). One lane == one task being worked.
#
# Storage: <cfg>/lanes/<task-id>.lane — trivially greppable key=value lines (NOT json):
#   owner=<name> started=<epoch> last_beat=<epoch> attempts=<n> status=running|done|dead
#
# Usage:
#   lane.sh start <id> --owner NAME [--target DIR]   init/restart; bumps attempts (restart-intensity)
#   lane.sh beat  <id> [--target DIR]                refresh last_beat (fail-soft: starts if absent)
#   lane.sh status <id> [--target DIR]               print the lane record (exit 1 if absent)
#   lane.sh list  [--target DIR]                     one line/lane: id status owner age attempts
#   lane.sh reap  [--threshold SECS] [--mark] [--target DIR]   list stale running lanes (DEAD); --mark sets status=dead
#   lane.sh clear <id> [--target DIR]                remove the lane file (call on verified/done)
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SELF_DIR/lib.sh"

lanes_dir() { printf '%s\n' "$(il_cfg_dir "$1")/lanes"; }
lane_file() { printf '%s\n' "$(lanes_dir "$1")/$2.lane"; }

# read one key's value from a lane file (empty if file/key absent)
_lane_get() { # <file> <key>
  [ -f "$1" ] || return 0
  sed -n "s/^$2=//p" "$1" | head -1
}

# (re)write the whole lane record from explicit fields
_lane_write() { # <file> owner started last_beat attempts status
  { printf 'owner=%s\n'     "$2"
    printf 'started=%s\n'   "$3"
    printf 'last_beat=%s\n' "$4"
    printf 'attempts=%s\n'  "$5"
    printf 'status=%s\n'    "$6"
  } > "$1"
}

CMD="${1:-}"; [ "$#" -gt 0 ] && shift
OWNER="" TARGET="$PWD" THRESHOLD=1800 MARK=0
POS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --owner)     [ "$#" -ge 2 ] || { echo "lane.sh: --owner requires a value" >&2; exit 64; }; OWNER="$2"; shift 2 ;;
    --target)    [ "$#" -ge 2 ] || { echo "lane.sh: --target requires a value" >&2; exit 64; }; TARGET="$2"; shift 2 ;;
    --threshold) [ "$#" -ge 2 ] || { echo "lane.sh: --threshold requires a value" >&2; exit 64; }; THRESHOLD="$2"; shift 2 ;;
    --mark)      MARK=1; shift ;;
    -*)          echo "lane.sh: unknown flag '$1'" >&2; exit 64 ;;
    *)           POS+=("$1"); shift ;;
  esac
done
ID="${POS[0]:-}"
TARGET="${TARGET%/}"; [ -n "$TARGET" ] || TARGET="/"

case "$CMD" in
  start)
    [ -n "$ID" ]    || { echo "lane.sh: start requires <task-id>" >&2; exit 64; }
    [ -n "$OWNER" ] || { echo "lane.sh: start requires --owner NAME" >&2; exit 64; }
    dir="$(lanes_dir "$TARGET")"; mkdir -p "$dir"
    f="$(lane_file "$TARGET" "$ID")"
    now="$(date +%s)"
    started="$now" attempts=0
    if [ -f "$f" ]; then
      started="$(_lane_get "$f" started)"; [ -n "$started" ] || started="$now"
      attempts="$(_lane_get "$f" attempts)"; [ -n "$attempts" ] || attempts=0
    fi
    attempts=$((attempts + 1))
    _lane_write "$f" "$OWNER" "$started" "$now" "$attempts" running
    # a re-start (attempts>1) is a restart-intensity event worth scoring
    [ "$attempts" -gt 1 ] && [ -x "$SELF_DIR/metric.sh" ] && \
      "$SELF_DIR/metric.sh" emit restart --task "$ID" --detail "attempt $attempts" --target "$TARGET" >/dev/null 2>&1 || true
    echo "lane: started $ID owner=$OWNER attempts=$attempts"
    ;;

  beat)
    [ -n "$ID" ] || { echo "lane.sh: beat requires <task-id>" >&2; exit 64; }
    dir="$(lanes_dir "$TARGET")"; mkdir -p "$dir"
    f="$(lane_file "$TARGET" "$ID")"
    now="$(date +%s)"
    if [ -f "$f" ]; then
      owner="$(_lane_get "$f" owner)"
      started="$(_lane_get "$f" started)"; [ -n "$started" ] || started="$now"
      attempts="$(_lane_get "$f" attempts)"; [ -n "$attempts" ] || attempts=1
      status="$(_lane_get "$f" status)"; [ -n "$status" ] || status=running
      _lane_write "$f" "$owner" "$started" "$now" "$attempts" "$status"
    else
      # fail-soft: a beat on a never-started lane behaves like a minimal start
      _lane_write "$f" "?" "$now" "$now" 1 running
    fi
    echo "lane: beat $ID"
    ;;

  status)
    [ -n "$ID" ] || { echo "lane.sh: status requires <task-id>" >&2; exit 64; }
    f="$(lane_file "$TARGET" "$ID")"
    if [ -f "$f" ]; then cat "$f"; exit 0
    else echo "lane: no lane for '$ID'" >&2; exit 1; fi
    ;;

  list)
    dir="$(lanes_dir "$TARGET")"
    [ -d "$dir" ] || exit 0
    now="$(date +%s)"
    for f in "$dir"/*.lane; do
      [ -e "$f" ] || continue
      id="$(basename "$f" .lane)"
      s="$(_lane_get "$f" status)"; o="$(_lane_get "$f" owner)"
      a="$(_lane_get "$f" attempts)"
      lb="$(_lane_get "$f" last_beat)"; [ -n "$lb" ] || lb="$now"
      printf '%s status=%s owner=%s age=%s attempts=%s\n' "$id" "${s:-?}" "${o:-?}" "$((now - lb))" "${a:-?}"
    done
    exit 0
    ;;

  reap)
    dir="$(lanes_dir "$TARGET")"
    [ -d "$dir" ] || exit 0
    now="$(date +%s)"
    for f in "$dir"/*.lane; do
      [ -e "$f" ] || continue
      [ "$(_lane_get "$f" status)" = running ] || continue
      lb="$(_lane_get "$f" last_beat)"; [ -n "$lb" ] || continue
      age=$((now - lb))
      if [ "$age" -gt "$THRESHOLD" ]; then
        id="$(basename "$f" .lane)"
        printf '%s DEAD age=%s\n' "$id" "$age"
        if [ "$MARK" = 1 ]; then
          _lane_write "$f" "$(_lane_get "$f" owner)" "$(_lane_get "$f" started)" "$lb" "$(_lane_get "$f" attempts)" dead
        fi
      fi
    done
    exit 0
    ;;

  clear)
    [ -n "$ID" ] || { echo "lane.sh: clear requires <task-id>" >&2; exit 64; }
    rm -f "$(lane_file "$TARGET" "$ID")"
    echo "lane: cleared $ID"
    ;;

  ""|-h|--help|help)
    sed -n '2,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
    [ -n "$CMD" ] && exit 0 || exit 64
    ;;

  *)
    echo "lane.sh: unknown subcommand '$CMD' (start|beat|status|list|reap|clear)" >&2
    exit 64
    ;;
esac
