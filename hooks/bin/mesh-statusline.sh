#!/usr/bin/env bash
# Terminal statusline hook: render the latest cached mesh snapshot without
# touching the daemon or running project-discovery commands.
set -uo pipefail

PROJECT="${CLAUDE_PROJECT_DIR:-$PWD}"
MESH_HOME="${WORKBENCH_HOME:-$HOME/.workbench}"
STATUS_DIR="$MESH_HOME/mesh/statusline"

json_string() {
  local json="$1" key="$2"
  printf '%s' "$json" \
    | sed -n "s/.*\"$key\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" \
    | head -1
}

json_number() {
  local json="$1" key="$2"
  printf '%s' "$json" \
    | sed -n "s/.*\"$key\"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p" \
    | head -1
}

json_array_strings() {
  local json="$1" key="$2" array
  array="$(printf '%s' "$json" | sed -n "s/.*\"$key\"[[:space:]]*:[[:space:]]*\[\([^]]*\)\].*/\1/p" | head -1)"
  [ -n "$array" ] || return 0
  printf '%s' "$array" | grep -o '"[^"]*"' | sed 's/^"//; s/"$//' | paste -sd ',' - | sed 's/,/, /g'
}

project_name() {
  basename "$PROJECT"
}

project_id() {
  local slug
  slug="$(project_name | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9_-]+/-/g; s/^-+//; s/-+$//')"
  [ -n "$slug" ] && printf '%s\n' "$slug" || printf 'project\n'
}

[ -d "$STATUS_DIR" ] || exit 0

snapshot="$STATUS_DIR/$(project_id).json"
if [ ! -f "$snapshot" ]; then
  snapshot=""
  for candidate in "$STATUS_DIR"/*.json; do
    [ -f "$candidate" ] || continue
    snapshot="$candidate"
    break
  done
fi
[ -n "${snapshot:-}" ] && [ -f "$snapshot" ] || exit 0

json="$(tr -d '\n' < "$snapshot" 2>/dev/null || true)"
[ -n "$json" ] || exit 0

actor="$(json_string "$json" current_actor)"; [ -n "$actor" ] || actor="solo"
availability="$(json_string "$json" availability)"; [ -n "$availability" ] || availability="offline"
doing="$(json_string "$json" doing)"
active="$(json_number "$json" active_count)"; [ -n "$active" ] || active=0
stale="$(json_number "$json" stale_count)"; [ -n "$stale" ] || stale=0
watched="$(json_array_strings "$json" watched)"
unread="$(json_number "$json" unread_mentions)"; [ -n "$unread" ] || unread=0

activity="$availability"
[ -n "$doing" ] && activity="$availability: $doing"

line="workbench | $actor | $activity | team $active active, $stale stale"
[ -n "$watched" ] && line="$line | watching $watched"
[ "$unread" -gt 0 ] 2>/dev/null && line="$line | $unread unread"

printf '%s\n' "$line"
exit 0
