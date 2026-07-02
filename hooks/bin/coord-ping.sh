#!/usr/bin/env bash
# workbench PostToolUse hook. Refreshes this session's coord presence heartbeat
# (cheap, throttled). No-ops unless this is a workbench project with coord scripts.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SELF_DIR/../../scripts/lib.sh" 2>/dev/null || exit 0
P="$(il_project_root "${CLAUDE_PROJECT_DIR:-$PWD}")"
[ -f "$(il_cfg_dir "$P")/config.json" ] || exit 0
il_hooks_enabled "$P" || exit 0
[ -x "$P/scripts/coord/wb-coord" ] || exit 0
# Anchor on CLAUDE_PROJECT_DIR so the heartbeat lands in THIS project's lock dir,
# matching where the SessionStart brief reads from (regardless of cwd).
WB_WORKSPACE_ROOT="$P" "$P/scripts/coord/wb-coord" ping --throttle 25 >/dev/null 2>&1 || true
exit 0
