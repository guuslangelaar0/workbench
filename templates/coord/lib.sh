#!/usr/bin/env bash
# Shared helpers for multi-session coordination (A+B+C).
#
# Sourced by: bb-coord, with-lock.sh, precommit-guard.sh, bb-worktree.sh.
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
bb_workspace_root() {
  # Resolve the TOP-LEVEL workspace — the dir that owns .claude/tasks — NOT the
  # first .claude/ we hit. Sub-repos and git worktrees also carry a .claude/
  # (for .claude/worktrees/), so stopping at the first one scattered lock dirs
  # into every repo/worktree and blocked `git worktree remove`. Anchor on the
  # unambiguous workspace-root marker instead.
  if [ -n "${BB_WORKSPACE_ROOT:-}" ]; then printf '%s\n' "$BB_WORKSPACE_ROOT"; return 0; fi
  local d; d="$(pwd -P)"
  while [ "$d" != "/" ]; do
    { [ -f "$d/.workbench/config.json" ] || [ -f "$d/.initlab/config.json" ] || [ -d "$d/.claude/tasks" ] || [ -f "$d/.claude/CODEX_COORDINATION.md" ]; } && { printf '%s\n' "$d"; return 0; }
    d="$(dirname "$d")"
  done
  # Fallbacks: Claude's project dir, else cwd.
  printf '%s\n' "${CLAUDE_PROJECT_DIR:-$(pwd -P)}"
}

BB_ROOT="$(bb_workspace_root)"
BB_LOCKS_DIR="$BB_ROOT/.claude/locks"
BB_SESSIONS_DIR="$BB_LOCKS_DIR/sessions"

# Heartbeat freshness windows (seconds).
BB_SESSION_TTL="${BB_SESSION_TTL:-120}"   # a session is "live" if pinged within this
BB_LOCK_TTL="${BB_LOCK_TTL:-60}"          # a lock is "held" if heartbeat within this

bb_now()      { date +%s; }
bb_now_iso()  { date -u +%Y-%m-%dT%H:%M:%SZ; }

# Stable per-tab identity. CLAUDE_CODE_SESSION_ID is present in every Bash call
# inside a Claude Code session; fall back for plain shells / other agents.
bb_sid() {
  local sid="${BB_SID_OVERRIDE:-${CLAUDE_CODE_SESSION_ID:-${TERM_SESSION_ID:-}}}"
  [ -z "$sid" ] && sid="$(id -un 2>/dev/null || echo user)@$(hostname -s 2>/dev/null || echo host)#${PPID:-0}"
  # sanitize for use as a filename
  printf '%s' "$sid" | tr -c 'A-Za-z0-9_.@-' '_'
}

# Short, human-friendly form of an sid for display.
bb_sid_short() { printf '%s' "${1:-$(bb_sid)}" | tail -c 12; }

# Read one top-level string/number field from a flat JSON file (no jq needed).
# usage: bb_json_get <file> <key>
bb_json_get() {
  [ -f "$1" ] || return 1
  sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\{0,1\}\([^\",}]*\)\"\{0,1\}.*/\1/p" "$1" | head -1
}

# Is a heartbeat_epoch within ttl of now?
bb_is_fresh() { # <heartbeat_epoch> <ttl>
  local hb="${1:-0}" ttl="${2:-$BB_SESSION_TTL}" now; now="$(bb_now)"
  [ -n "$hb" ] && [ "$hb" -gt 0 ] 2>/dev/null && [ $(( now - hb )) -le "$ttl" ]
}

bb_ensure_dirs() { mkdir -p "$BB_SESSIONS_DIR"; }

# Colour helpers (no-op when not a tty / NO_COLOR set)
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  BB_DIM=$'\033[2m'; BB_RED=$'\033[31m'; BB_YEL=$'\033[33m'; BB_GRN=$'\033[32m'; BB_BOLD=$'\033[1m'; BB_RST=$'\033[0m'
else
  BB_DIM=""; BB_RED=""; BB_YEL=""; BB_GRN=""; BB_BOLD=""; BB_RST=""
fi
