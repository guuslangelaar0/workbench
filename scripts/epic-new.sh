#!/usr/bin/env bash
# workbench: create a new epic file in .claude/epics/, allocate the next ID from the
# SHARED .claude/tasks/_next-id (so epic and task IDs never collide), render the epic
# template, and bump the ID. Deterministic + python-free (the /workbench:epic command
# wraps this). Epics group tasks; a task joins an epic via `task-new.sh --epic <id>`.
#
# Usage: epic-new.sh --title "<title>" [--target DIR] [--theme "<theme>"] [--status open|done]
set -euo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # workbench/scripts
PLUGIN_ROOT="$(cd "$SELF_DIR/.." && pwd)"                  # workbench
. "$SELF_DIR/lib.sh"

TITLE="" TARGET="$PWD" THEME="(none)" STATUS="open"
need_arg() { [ "$#" -ge 2 ] || { echo "epic-new.sh: $1 requires a value" >&2; exit 64; }; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --title)  need_arg "$@"; TITLE="$2"; shift 2 ;;
    --target) need_arg "$@"; TARGET="$2"; shift 2 ;;
    --theme)  need_arg "$@"; THEME="$2"; shift 2 ;;
    --status) need_arg "$@"; STATUS="$2"; shift 2 ;;
    *) echo "epic-new.sh: unknown arg '$1'" >&2; exit 64 ;;
  esac
done
[ -n "$TITLE" ] || { echo "epic-new.sh: --title is required" >&2; exit 64; }
case "$STATUS" in open|done) ;; *) echo "epic-new.sh: --status must be open|done" >&2; exit 64 ;; esac
TARGET="${TARGET%/}"; [ -n "$TARGET" ] || TARGET="/"

# shared global ID counter lives under .claude/tasks/ (epics + tasks draw from it)
NID="$TARGET/.claude/tasks/_next-id"
[ -f "$NID" ] || { echo "epic-new.sh: no $NID (run /workbench:init first?)" >&2; exit 1; }
ID="$(tr -d ' \n' < "$NID")"
case "$ID" in ''|*[!0-9]*) echo "epic-new.sh: _next-id is not numeric: '$ID'" >&2; exit 1 ;; esac

slug="$(printf '%s' "$TITLE" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')"
[ -n "$slug" ] || slug="epic"

E="$TARGET/.claude/epics"
mkdir -p "$E"
OUT="$E/$ID-$slug.md"
CREATED="$(date -u +%Y-%m-%d)"
il_render "$PLUGIN_ROOT/templates/minimal/tasks/epic.md.tmpl" "$OUT" \
  "ID=$ID" "TITLE=$TITLE" "STATUS=$STATUS" "THEME=$THEME" "CREATED=$CREATED"

printf '%04d\n' "$((10#$ID + 1))" > "$NID"
echo "workbench: created $OUT (epic $ID)"
