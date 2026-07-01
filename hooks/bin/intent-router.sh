#!/usr/bin/env bash
# UserPromptSubmit hook: add a tiny routing hint for natural Workbench intents.
# Offline-only and deterministic; it never mutates project state.
set -uo pipefail

PROJECT="${CLAUDE_PROJECT_DIR:-$PWD}"
input="$(cat)"

json_string_from() {
  local json="$1" key="$2"
  printf '%s' "$json" \
    | sed -n "s/.*\"$key\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" \
    | head -1
}

json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}

level() {
  local cfg="$PROJECT/.workbench/config.json" lvl
  [ -f "$cfg" ] || return 0
  lvl="$(sed -n 's/.*"level"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$cfg" | head -1)"
  printf '%s' "$lvl"
}

prompt="$(json_string_from "$input" prompt)"
[ -n "$prompt" ] || exit 0
lc="$(printf '%s' "$prompt" | tr '[:upper:]' '[:lower:]')"
hint=""

case "$lc" in
  *"grab the next"*|*"pull the next"*|*"next feature from the backlog"*|*"next task from the backlog"*|*"what can i pick up now"*)
    hint="Workbench intent router: this is a request to pick next work. Use /workbench:next first; it checks the in-review cap and Blocked-by dependencies. Do not spawn an engineer or dispatch until /workbench:next reports a safe task."
    ;;
  *"start building "*|*"start work on "*|*"let's start work on "*|*"lets start work on "*)
    if printf '%s' "$lc" | grep -Eq 'checkout|flow|from the backlog|next feature|next task'; then
      hint="Workbench intent router: this looks like starting existing/backlog work. Use /workbench:next with the title/id hint first; report cap pressure or unfinished Blocked-by dependencies before dispatching."
    else
      hint="Workbench intent router: this is committed concrete work. Create a tracked task with /workbench:task before implementation; then check cap/dependencies before dispatching."
    fi
    ;;
  *"plaintext password"*|*"passwords into"*|*"secret leak"*|*"security bug"*|*"privacy bug"*)
    hint="Workbench intent router: this is a bug/security report. Auto-file it with /workbench:task even if the affected repo/path is missing; record missing code location as the first blocker instead of only discussing it."
    ;;
  *"architectural call"*|*"expensive to reverse"*|*"per-user key"*|*"master key"*|*"should we encrypt"*|*"schema fork"*|*"dependency swap"*)
    hint="Workbench intent router: this is an irreversible decision fork. Capture it with /workbench:decision in .claude/tasks/decisions/; give compact options/tradeoffs and do not implement until resolved."
    ;;
  *"multi-part effort"*|*"full billing system"*|*"subscriptions, invoices"*|*"theme"*|*"initiative"*)
    if [ "$(level)" = "fleet" ]; then
      hint="Workbench intent router: this is fleet-level decomposition. Create an epic with /workbench:epic so the plan exists on disk before child tasks."
    else
      hint="Workbench intent router: this is multi-part planning. Capture it as tracked backlog tasks (or an epic if this level supports epics), not only prose in chat."
    fi
    ;;
esac

[ -n "$hint" ] || exit 0
printf '{\n  "hookSpecificOutput": {\n    "hookEventName": "UserPromptSubmit",\n    "additionalContext": "%s"\n  }\n}\n' "$(json_escape "$hint")"
