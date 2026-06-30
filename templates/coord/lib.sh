#!/usr/bin/env bash
# Shared helpers for multi-session coordination (A+B+C).
#
# Sourced by: wb-coord, with-lock.sh, precommit-guard.sh, bb-worktree.sh.
#
# Concept: every Claude Code tab is an independent process that shares only the
# filesystem. We coordinate through files under .claude/locks/ at the WORKSPACE
# ROOT (so all repos/sessions see the same state):
#
#   .claude/locks/sessions/<sid>.json   presence/heartbeat per live session (C)
#   .claude/locks/<name>.lock           held action locks (B, and 0618 deploys)
#
# These are runtime state, never committed (.gitignore'd).

# --- locate the workspace root (the dir that holds .claude/) -----------------
wb_workspace_root() {
  # Resolve the TOP-LEVEL workspace — the dir that owns .claude/tasks — NOT the
  # first .claude/ we hit. Sub-repos and git worktrees also carry a .claude/
  # (for .claude/worktrees/), so stopping at the first one scattered lock dirs
  # into every repo/worktree and blocked `git worktree remove`. Anchor on the
  # unambiguous workspace-root marker instead.
  if [ -n "${WB_WORKSPACE_ROOT:-}" ]; then printf '%s\n' "$WB_WORKSPACE_ROOT"; return 0; fi
  local d; d="$(pwd -P)"
  while [ "$d" != "/" ]; do
    { [ -f "$d/.workbench/config.json" ] || [ -f "$d/.initlab/config.json" ] || [ -d "$d/.claude/tasks" ] || [ -f "$d/.claude/CODEX_COORDINATION.md" ]; } && { printf '%s\n' "$d"; return 0; }
    d="$(dirname "$d")"
  done
  # Fallbacks: Claude's project dir, else cwd.
  printf '%s\n' "${CLAUDE_PROJECT_DIR:-$(pwd -P)}"
}

WB_ROOT="$(wb_workspace_root)"
WB_LOCKS_DIR="$WB_ROOT/.claude/locks"
WB_SESSIONS_DIR="$WB_LOCKS_DIR/sessions"

# Heartbeat freshness windows (seconds).
WB_SESSION_TTL="${WB_SESSION_TTL:-120}"   # a session is "live" if pinged within this
WB_LOCK_TTL="${WB_LOCK_TTL:-60}"          # a lock is "held" if heartbeat within this

wb_now()      { date +%s; }
wb_now_iso()  { date -u +%Y-%m-%dT%H:%M:%SZ; }

# Stable per-tab identity. CLAUDE_CODE_SESSION_ID is present in every Bash call
# inside a Claude Code session; fall back for plain shells / other agents.
wb_sid() {
  local sid="${WB_SID_OVERRIDE:-${CLAUDE_CODE_SESSION_ID:-${TERM_SESSION_ID:-}}}"
  [ -z "$sid" ] && sid="$(id -un 2>/dev/null || echo user)@$(hostname -s 2>/dev/null || echo host)#${PPID:-0}"
  # sanitize for use as a filename
  printf '%s' "$sid" | tr -c 'A-Za-z0-9_.@-' '_'
}

# Short, human-friendly form of an sid for display.
wb_sid_short() { printf '%s' "${1:-$(wb_sid)}" | tail -c 12; }

# Read one top-level string/number field from a flat JSON file (no jq needed).
# usage: wb_json_get <file> <key>
wb_json_get() {
  [ -f "$1" ] || return 1
  sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\{0,1\}\([^\",}]*\)\"\{0,1\}.*/\1/p" "$1" | head -1
}

# Is a heartbeat_epoch within ttl of now?
wb_is_fresh() { # <heartbeat_epoch> <ttl>
  local hb="${1:-0}" ttl="${2:-$WB_SESSION_TTL}" now; now="$(wb_now)"
  [ -n "$hb" ] && [ "$hb" -gt 0 ] 2>/dev/null && [ $(( now - hb )) -le "$ttl" ]
}

wb_ensure_dirs() { mkdir -p "$WB_SESSIONS_DIR"; }

# Colour helpers (no-op when not a tty / NO_COLOR set)
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  WB_DIM=$'\033[2m'; WB_RED=$'\033[31m'; WB_YEL=$'\033[33m'; WB_GRN=$'\033[32m'; WB_BOLD=$'\033[1m'; WB_RST=$'\033[0m'
else
  WB_DIM=""; WB_RED=""; WB_YEL=""; WB_GRN=""; WB_BOLD=""; WB_RST=""
fi

# --- legacy (bb_) compat bridge ----------------------------------------------
# This lib was renamed bb_*/BB_* -> wb_*/WB_* in the initlab->workbench rename.
# `init.sh` is greenfield-only (never overwrites an existing coord file), so a
# project upgraded from initlab can end up with the NEW wb-coord beside an OLD
# bb_-prefixed lib.sh (or vice-versa) until /workbench:upgrade refreshes it —
# and the script then crashes on an undefined symbol. Define the legacy bb_*
# names as aliases so the coord set degrades gracefully in any mixed state.
# Harmless on fresh installs; safe to drop once no initlab-era projects remain.
BB_ROOT="$WB_ROOT"; BB_LOCKS_DIR="$WB_LOCKS_DIR"; BB_SESSIONS_DIR="$WB_SESSIONS_DIR"
BB_SESSION_TTL="$WB_SESSION_TTL"; BB_LOCK_TTL="$WB_LOCK_TTL"
BB_DIM="$WB_DIM"; BB_RED="$WB_RED"; BB_YEL="$WB_YEL"; BB_GRN="$WB_GRN"; BB_BOLD="$WB_BOLD"; BB_RST="$WB_RST"
BB_LABEL="${BB_LABEL:-${WB_LABEL:-}}"
bb_workspace_root() { wb_workspace_root "$@"; }
bb_now()         { wb_now; }
bb_now_iso()     { wb_now_iso; }
bb_sid()         { wb_sid; }
bb_sid_short()   { wb_sid_short "$@"; }
bb_json_get()    { wb_json_get "$@"; }
bb_is_fresh()    { wb_is_fresh "$@"; }
bb_ensure_dirs() { wb_ensure_dirs; }
