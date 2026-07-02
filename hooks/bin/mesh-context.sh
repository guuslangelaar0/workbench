#!/usr/bin/env bash
# Inject mesh operating context from local metadata and cached status snapshots.
# This is intentionally offline-only: no daemon, network, or jq dependency.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SELF_DIR/../../scripts/lib.sh" 2>/dev/null || exit 0
PROJECT="$(il_project_root "${CLAUDE_PROJECT_DIR:-$PWD}")"
[ -f "$(il_cfg_dir "$PROJECT")/config.json" ] || exit 0
il_hooks_enabled "$PROJECT" || exit 0
MESH_HOME="${WORKBENCH_HOME:-$HOME/.workbench}"
STATUS_DIR="$MESH_HOME/mesh/statusline"

input="$(cat)"

json_string_from() {
  local json="$1" key="$2"
  printf '%s' "$json" \
    | sed -n "s/.*\"$key\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" \
    | head -1
}

json_number_from() {
  local json="$1" key="$2"
  printf '%s' "$json" \
    | sed -n "s/.*\"$key\"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p" \
    | head -1
}

json_array_strings_from() {
  local json="$1" key="$2" array
  array="$(printf '%s' "$json" | sed -n "s/.*\"$key\"[[:space:]]*:[[:space:]]*\[\([^]]*\)\].*/\1/p" | head -1)"
  [ -n "$array" ] || return 0
  printf '%s' "$array" | grep -o '"[^"]*"' | sed 's/^"//; s/"$//' | paste -sd ',' - | sed 's/,/, /g'
}

json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}

json_has_key() {
  local json="$1" key="$2"
  printf '%s' "$json" | grep -Eq "\"$key\"[[:space:]]*:"
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

project_id() {
  sanitize_project_id "$(project_name)"
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

status_snapshot() {
  local snapshot
  [ -d "$STATUS_DIR" ] || return 1
  snapshot="$STATUS_DIR/$(project_id).json"
  [ -f "$snapshot" ] || return 1
  tr -d '\n' < "$snapshot" 2>/dev/null || true
}

metadata_url() {
  local meta json host port
  meta="$PROJECT/.workbench/mesh/server.json"
  [ -f "$meta" ] || return 1
  json="$(tr -d '\n' < "$meta" 2>/dev/null || true)"
  host="$(json_string_from "$json" host)"
  port="$(json_number_from "$json" port)"
  [ -n "$host" ] && [ -n "$port" ] || return 1
  printf 'http://%s:%s\n' "$host" "$port"
}

mesh_status="Mesh server metadata: not found at .workbench/mesh/server.json; mesh may be stopped or not started."
url="$(metadata_url || true)"
if [ -n "$url" ]; then
  mesh_status="Mesh server metadata: found. Command center: $url. Use /workbench:mesh open for local authenticated access."
fi

snapshot_json="$(status_snapshot || true)"
if [ -n "$snapshot_json" ]; then
  actor="$(json_string_from "$snapshot_json" current_actor)"; [ -n "$actor" ] || actor="solo"
  availability="$(json_string_from "$snapshot_json" availability)"; [ -n "$availability" ] || availability="offline"
  doing="$(json_string_from "$snapshot_json" doing)"
  active="$(json_number_from "$snapshot_json" active_count)"; [ -n "$active" ] || active=0
  stale="$(json_number_from "$snapshot_json" stale_count)"; [ -n "$stale" ] || stale=0
  watched="$(json_array_strings_from "$snapshot_json" watched)"
  unread="$(json_number_from "$snapshot_json" unread_mentions)"; [ -n "$unread" ] || unread=0
  pulse="Cached mesh pulse: $active active, $stale stale. Current actor: $actor. Availability: $availability${doing:+, doing: $doing}.${watched:+ Watching: $watched.} Unread mentions: $unread."
else
  pulse="Cached mesh pulse: no statusline snapshot found under $STATUS_DIR."
fi

context="$(cat <<TEXT
Workbench mesh context:
- $mesh_status
- $pulse
- When the user asks for teammate status, help, handoff, messages, jobs, invites, or command-center access, answer in outcomes and call /workbench:mesh commands yourself; do not ask the user to run them.
TEXT
)"

event="$(json_string_from "$input" hook_event_name)"
if [ "$event" = "SessionStart" ]; then
  printf '%s\n' "$context"
  exit 0
fi

if [ "$event" != "UserPromptSubmit" ] && ! json_has_key "$input" prompt && ! printf '%s' "$input" | grep -q 'UserPromptSubmit'; then
  printf '%s\n' "$context"
  exit 0
fi

printf '{\n  "hookSpecificOutput": {\n    "hookEventName": "UserPromptSubmit",\n    "additionalContext": "%s"\n  }\n}\n' "$(json_escape "$context")"
exit 0
