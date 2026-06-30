#!/usr/bin/env bash
# workbench parking: create a real backlog task for out-of-scope work, with
# origin metadata so the lead can resume it later without derailing this branch.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TYPE="follow-up" TITLE="" TARGET="$PWD" SESSION_ID="${CLAUDE_SESSION_ID:-}" ORIGIN_TASK="" ORIGIN_PURPOSE="" CONTEXT_FILE=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --type)           TYPE="${2:-}"; shift 2 ;;
    --title)          TITLE="${2:-}"; shift 2 ;;
    --target)         TARGET="${2:-}"; shift 2 ;;
    --session-id)     SESSION_ID="${2:-}"; shift 2 ;;
    --origin-task)    ORIGIN_TASK="${2:-}"; shift 2 ;;
    --origin-purpose) ORIGIN_PURPOSE="${2:-}"; shift 2 ;;
    --context-file)   CONTEXT_FILE="${2:-}"; shift 2 ;;
    -*) echo "park.sh: unknown flag '$1'" >&2; exit 64 ;;
    *)  echo "park.sh: unexpected arg '$1'" >&2; exit 64 ;;
  esac
done

case "$TYPE" in bug|feature|follow-up) ;; *) echo "park.sh: --type must be bug|feature|follow-up" >&2; exit 64 ;; esac
[ -n "$TITLE" ] || { echo "park.sh: --title is required" >&2; exit 64; }
TARGET="${TARGET%/}"; [ -n "$TARGET" ] || TARGET="/"
[ -n "$SESSION_ID" ] || SESSION_ID="default"

branch="$(git -C "$TARGET" symbolic-ref --quiet --short HEAD 2>/dev/null || git -C "$TARGET" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "-")"
out="$(bash "$SELF_DIR/task-new.sh" \
  --title "$TITLE" \
  --target "$TARGET" \
  --track parked \
  --verification "define verification before dispatching this parked work")" || exit $?

task_path="$(printf '%s\n' "$out" | sed -n 's/^workbench: created \(.*\) (id .*/\1/p' | head -1)"
[ -n "$task_path" ] && [ -f "$task_path" ] || { printf '%s\n' "$out"; echo "park.sh: could not locate created task" >&2; exit 1; }

{
  echo ""
  echo "## Parked origin"
  echo "**Parked-type:** $TYPE"
  echo "**Origin-session:** $SESSION_ID"
  echo "**Origin-task:** ${ORIGIN_TASK:-(none)}"
  echo "**Origin-purpose:** ${ORIGIN_PURPOSE:-(unset)}"
  echo "**Origin-branch:** $branch"
  echo ""
  echo "### Context"
  if [ -n "$CONTEXT_FILE" ] && [ -f "$CONTEXT_FILE" ]; then
    cat "$CONTEXT_FILE"
    case "$(tail -c 1 "$CONTEXT_FILE" 2>/dev/null)" in "") ;; *) echo "" ;; esac
  else
    echo "(capture the tangent context before dispatching this parked task)"
  fi
} >> "$task_path"

printf '%s\n' "$out"
echo "workbench: parked $TYPE as $task_path"
