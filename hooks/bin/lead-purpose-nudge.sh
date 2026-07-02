#!/usr/bin/env bash
# UserPromptSubmit hook: inject the current lead purpose so tangents are parked
# instead of silently expanding the active task.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
. "$PLUGIN_ROOT/scripts/lib.sh" 2>/dev/null || exit 0
PROJECT="$(il_project_root "${CLAUDE_PROJECT_DIR:-$PWD}")"
[ -f "$(il_cfg_dir "$PROJECT")/config.json" ] || exit 0
il_hooks_enabled "$PROJECT" || exit 0
LEAD="$PLUGIN_ROOT/scripts/lead.sh"
[ -x "$LEAD" ] || exit 0

input="$(cat)"
get_json_string() {
  printf '%s' "$input" \
    | grep -o "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" \
    | head -1 \
    | sed "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"//; s/\"$//"
}
sid="$(get_json_string session_id)"
[ -n "$sid" ] || sid="${CLAUDE_SESSION_ID:-default}"

current="$("$LEAD" status --target "$PROJECT" --session-id "$sid" 2>/dev/null || true)"
if [ -z "$current" ]; then
  latest="$("$LEAD" latest-open --target "$PROJECT" 2>/dev/null || true)"
  if [ -z "$latest" ]; then
    msg="No workbench lead purpose is set for this session. If you are acting as a lead, establish one with /workbench:lead set \"<purpose>\" or pick from backlog before starting implementation."
    title="lead:unassigned"
  else
    lp="$(printf '%s\n' "$latest" | sed -n 's/^purpose=//p' | head -1)"
    lt="$(printf '%s\n' "$latest" | sed -n 's/^active_task=//p' | head -1)"
    msg="No purpose is set for this session. Latest open lead purpose is '${lp:-unset}'${lt:+ (task $lt)}. Continue that purpose with /workbench:lead adopt, or pick from backlog and set a new purpose."
    title="lead:resume"
  fi
else
  purpose="$(printf '%s\n' "$current" | sed -n 's/^purpose=//p' | head -1)"
  task="$(printf '%s\n' "$current" | sed -n 's/^active_task=//p' | head -1)"
  mode="$(printf '%s\n' "$current" | sed -n 's/^mode=//p' | head -1)"
  track="$(printf '%s\n' "$current" | sed -n 's/^track=//p' | head -1)"
  msg="Current workbench lead purpose: ${purpose:-unset} (mode ${mode:-unassigned}${task:+, task $task}${track:+, track $track}). If this prompt or the work it implies is not clearly part of that purpose, park it as a backlog task with /workbench:park instead of expanding the active feature."
  if [ -n "$task" ]; then
    title="lead:$task $(printf '%s' "$purpose" | cut -c1-40)"
  else
    title="lead:${track:-purpose}"
  fi
fi

escape_json() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  printf '%s' "$s"
}

printf '{\n  "hookSpecificOutput": {\n    "hookEventName": "UserPromptSubmit",\n    "additionalContext": "%s"\n  },\n  "sessionTitle": "%s"\n}\n' "$(escape_json "$msg")" "$(escape_json "$title")"
