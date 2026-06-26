#!/usr/bin/env bash
# initlab PostToolUse hook. Refreshes this session's coord presence heartbeat
# (cheap, throttled). No-ops unless this is an initlab project with coord scripts.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SELF_DIR/../../scripts/lib.sh"
P="${CLAUDE_PROJECT_DIR:-$PWD}"
[ -f "$(il_cfg_dir "$P")/config.json" ] || exit 0
[ -x "$P/scripts/coord/bb-coord" ] || exit 0
# Anchor on CLAUDE_PROJECT_DIR so the heartbeat lands in THIS project's lock dir,
# matching where the SessionStart brief reads from (regardless of cwd).
BB_WORKSPACE_ROOT="$P" "$P/scripts/coord/bb-coord" ping --throttle 25 >/dev/null 2>&1 || true
exit 0
