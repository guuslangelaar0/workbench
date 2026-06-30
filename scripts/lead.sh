#!/usr/bin/env bash
# workbench lead purpose store. A lead session should have one durable purpose:
# a task, track, backlog-scouting pass, or explicit unassigned state.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SELF_DIR/lib.sh"

lead_dir() { printf '%s\n' "$(il_cfg_dir "$1")/leads"; }
lead_slug() {
  local s="$1"
  s="$(printf '%s' "$s" | sed -E 's/[^A-Za-z0-9._-]+/-/g; s/^-+//; s/-+$//')"
  [ -n "$s" ] || s="default"
  printf '%s\n' "$s"
}
lead_file() { printf '%s\n' "$(lead_dir "$1")/$(lead_slug "$2").lead"; }
now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
get_key() { [ -f "$1" ] || return 0; sed -n "s/^$2=//p" "$1" | head -1; }
clean_line() { printf '%s' "$1" | tr '\n\t' '  '; }

usage() {
  sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit "${1:-64}"
}

CMD="${1:-}"; [ "$#" -gt 0 ] && shift || true
TARGET="$PWD" SESSION_ID="${CLAUDE_SESSION_ID:-}" MODE="unassigned" PURPOSE="" ACTIVE_TASK="" TRACK="" STATUS="open"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --target)      TARGET="${2:-}"; shift 2 ;;
    --session-id)  SESSION_ID="${2:-}"; shift 2 ;;
    --mode)        MODE="${2:-}"; shift 2 ;;
    --purpose)     PURPOSE="${2:-}"; shift 2 ;;
    --active-task) ACTIVE_TASK="${2:-}"; shift 2 ;;
    --track)       TRACK="${2:-}"; shift 2 ;;
    --status)      STATUS="${2:-}"; shift 2 ;;
    -*) echo "lead.sh: unknown flag '$1'" >&2; exit 64 ;;
    *)  echo "lead.sh: unexpected arg '$1'" >&2; exit 64 ;;
  esac
done

TARGET="${TARGET%/}"; [ -n "$TARGET" ] || TARGET="/"
[ -n "$SESSION_ID" ] || SESSION_ID="default"

case "$CMD" in
  set)
    case "$MODE" in task|track|backlog-scout|unassigned) ;; *) echo "lead.sh: --mode must be task|track|backlog-scout|unassigned" >&2; exit 64 ;; esac
    dir="$(lead_dir "$TARGET")"; mkdir -p "$dir"
    file="$(lead_file "$TARGET" "$SESSION_ID")"
    created="$(get_key "$file" created)"; [ -n "$created" ] || created="$(now_iso)"
    branch="$(git -C "$TARGET" symbolic-ref --quiet --short HEAD 2>/dev/null || git -C "$TARGET" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "-")"
    {
      printf 'session_id=%s\n' "$SESSION_ID"
      printf 'mode=%s\n' "$MODE"
      printf 'purpose=%s\n' "$(clean_line "$PURPOSE")"
      printf 'active_task=%s\n' "$(clean_line "$ACTIVE_TASK")"
      printf 'track=%s\n' "$(clean_line "$TRACK")"
      printf 'branch=%s\n' "$(clean_line "$branch")"
      printf 'status=%s\n' "$STATUS"
      printf 'parking_policy=backlog-task\n'
      printf 'created=%s\n' "$created"
      printf 'updated=%s\n' "$(now_iso)"
    } > "$file"
    echo "lead: set $(lead_slug "$SESSION_ID") ${PURPOSE:+- $PURPOSE}"
    ;;

  status|current)
    file="$(lead_file "$TARGET" "$SESSION_ID")"
    [ -f "$file" ] || { echo "lead: no purpose for $(lead_slug "$SESSION_ID")" >&2; exit 1; }
    cat "$file"
    ;;

  latest-open)
    dir="$(lead_dir "$TARGET")"
    [ -d "$dir" ] || { echo "lead: no open lead purpose" >&2; exit 1; }
    shopt -s nullglob
    latest="$(
      for file in "$dir"/*.lead; do
      [ "$(get_key "$file" status)" = open ] || continue
      printf '%s\t%s\n' "$(get_key "$file" updated)" "$file"
      done | sort -r | head -1
    )"
    [ -n "$latest" ] || { echo "lead: no open lead purpose" >&2; exit 1; }
    file="${latest#*$'\t'}"
    [ -n "$file" ] && [ -f "$file" ] || { echo "lead: no open lead purpose" >&2; exit 1; }
    cat "$file"
    ;;

  clear|close)
    file="$(lead_file "$TARGET" "$SESSION_ID")"
    [ -f "$file" ] || { echo "lead: no purpose for $(lead_slug "$SESSION_ID")" >&2; exit 1; }
    tmp="$file.$$"
    awk -v now="$(now_iso)" '
      BEGIN { saw_status=0; saw_updated=0 }
      /^status=/ { print "status=closed"; saw_status=1; next }
      /^updated=/ { print "updated=" now; saw_updated=1; next }
      { print }
      END {
        if (!saw_status) print "status=closed"
        if (!saw_updated) print "updated=" now
      }
    ' "$file" > "$tmp" && mv "$tmp" "$file"
    echo "lead: closed $(lead_slug "$SESSION_ID")"
    ;;

  ""|-h|--help|help)
    usage 0
    ;;

  *)
    echo "lead.sh: unknown subcommand '$CMD' (set|status|latest-open|clear)" >&2
    exit 64
    ;;
esac
