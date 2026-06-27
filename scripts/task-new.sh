#!/usr/bin/env bash
# workbench: create a new task file in <state> (default backlog), allocate the next
# ID from .claude/tasks/_next-id, render the canonical template, and bump the ID.
# Deterministic + python-free (the /workbench:task command wraps this).
#
# Usage: task-new.sh --title "<title>" [--target DIR] [--state backlog]
#        [--track T] [--repos "a,b"] [--estimate "~1 day"] [--verification "<how>"]
set -euo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # workbench/scripts
PLUGIN_ROOT="$(cd "$SELF_DIR/.." && pwd)"                  # workbench
. "$SELF_DIR/lib.sh"

TITLE="" TARGET="$PWD" STATE="backlog"
TRACK="general" REPOS="(unset)" ESTIMATE="(unestimated)" VERIF="(define how this is verified)" EPIC="(none)"
need_arg() { [ "$#" -ge 2 ] || { echo "task-new.sh: $1 requires a value" >&2; exit 64; }; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --title)        need_arg "$@"; TITLE="$2"; shift 2 ;;
    --target)       need_arg "$@"; TARGET="$2"; shift 2 ;;
    --state)        need_arg "$@"; STATE="$2"; shift 2 ;;
    --track)        need_arg "$@"; TRACK="$2"; shift 2 ;;
    --epic)         need_arg "$@"; EPIC="$2"; shift 2 ;;
    --repos)        need_arg "$@"; REPOS="$2"; shift 2 ;;
    --estimate)     need_arg "$@"; ESTIMATE="$2"; shift 2 ;;
    --verification) need_arg "$@"; VERIF="$2"; shift 2 ;;
    *) echo "task-new.sh: unknown arg '$1'" >&2; exit 64 ;;
  esac
done
[ -n "$TITLE" ] || { echo "task-new.sh: --title is required" >&2; exit 64; }
TARGET="${TARGET%/}"; [ -n "$TARGET" ] || TARGET="/"

T="$TARGET/.claude/tasks"
NID="$T/_next-id"
[ -f "$NID" ] || { echo "task-new.sh: no $NID (run /workbench:init first?)" >&2; exit 1; }
ID="$(tr -d ' \n' < "$NID")"
case "$ID" in ''|*[!0-9]*) echo "task-new.sh: _next-id is not numeric: '$ID'" >&2; exit 1 ;; esac

# slug: lowercase, runs of non-alphanumerics -> single '-', trim leading/trailing '-'
slug="$(printf '%s' "$TITLE" | tr '\n' ' ' | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')"
[ -n "$slug" ] || slug="task"

mkdir -p "$T/$STATE"
OUT="$T/$STATE/$ID-$slug.md"
CREATED="$(date -u +%Y-%m-%d)"
il_render "$PLUGIN_ROOT/templates/minimal/tasks/task.md.tmpl" "$OUT" \
  "ID=$ID" "TITLE=$TITLE" "STATUS=$STATE" "TRACK=$TRACK" "EPIC=$EPIC" "REPOS=$REPOS" \
  "ESTIMATE=$ESTIMATE" "CREATED=$CREATED" "VERIFICATION=$VERIF"

printf '%04d\n' "$((10#$ID + 1))" > "$NID"
echo "workbench: created $OUT (id $ID)"
