#!/usr/bin/env bash
# Terminal statusline hook: render the latest cached mesh snapshot without
# touching the daemon or running project-discovery commands.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SELF_DIR/../../scripts/lib.sh" 2>/dev/null || exit 0
PROJECT="$(il_project_root "${CLAUDE_PROJECT_DIR:-$PWD}")"
[ -f "$(il_cfg_dir "$PROJECT")/config.json" ] || exit 0
il_hooks_enabled "$PROJECT" || exit 0
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
  local cfg name
  cfg="$PROJECT/.workbench/config.json"
  [ -f "$cfg" ] || cfg="$PROJECT/.initlab/config.json"
  if [ -f "$cfg" ]; then
    name="$(sed -n 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$cfg" | head -1)"
    [ -n "$name" ] && { printf '%s\n' "$name"; return 0; }
  fi
  basename "$PROJECT"
}

sanitize_project_id() {
  awk -v value="$1" '
    BEGIN {
      out = ""
      for (i = 1; i <= length(value); i++) {
        ch = substr(value, i, 1)
        lower = tolower(ch)
        if (lower ~ /^[a-z0-9]$/) {
          out = out lower
        } else if (ch == "-" || ch == "_") {
          out = out ch
        } else if (out !~ /-$/) {
          out = out "-"
        }
      }
      gsub(/^-+|-+$/, "", out)
      print out == "" ? "project" : out
    }
  '
}

project_id() {
  sanitize_project_id "$(project_name)"
}

[ -d "$STATUS_DIR" ] || exit 0

snapshot="$STATUS_DIR/$(project_id).json"
[ -f "$snapshot" ] || exit 0

json="$(tr -d '\n' < "$snapshot" 2>/dev/null || true)"
[ -n "$json" ] || exit 0

project="$(project_id)"
actor="$(json_string "$json" current_actor)"; [ -n "$actor" ] || actor="solo"
availability="$(json_string "$json" availability)"; [ -n "$availability" ] || availability="offline"
doing="$(json_string "$json" doing)"
active="$(json_number "$json" active_count)"; [ -n "$active" ] || active=0
stale="$(json_number "$json" stale_count)"; [ -n "$stale" ] || stale=0
watched="$(json_array_strings "$json" watched)"
devices="$(json_array_strings "$json" devices)"
unread="$(json_number "$json" unread_mentions)"; [ -n "$unread" ] || unread=0

activity="$availability"
[ -n "$doing" ] && activity="$availability: $doing"

line="workbench/$project | $actor | $activity | team $active active, $stale stale"
[ -n "$watched" ] && line="$line | watching $watched"
[ -n "$devices" ] && line="$line | devices $devices"
[ "$unread" -gt 0 ] 2>/dev/null && line="$line | $unread unread"

printf '%s\n' "$line"
exit 0
