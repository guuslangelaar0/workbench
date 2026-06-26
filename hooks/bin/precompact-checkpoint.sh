#!/usr/bin/env bash
# workbench PreCompact hook. Fires BEFORE compaction. stdout is NOT injected, so
# this only writes a durable marker to disk; re-grounding happens on the next
# SessionStart (matcher "compact"). No-ops unless this is a workbench project.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SELF_DIR/../../scripts/lib.sh"
P="${CLAUDE_PROJECT_DIR:-$PWD}"
_cfg_dir="$(il_cfg_dir "$P")"
[ -f "$_cfg_dir/config.json" ] || exit 0
dir="$_cfg_dir/checkpoints"; mkdir -p "$dir"
input="$(cat 2>/dev/null || true)"
trigger="$(printf '%s' "$input" | sed -n 's/.*"trigger"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf '{ "ts": "%s", "trigger": "%s", "note": "context compaction; re-ground on next SessionStart" }\n' \
  "$ts" "${trigger:-unknown}" > "$dir/last-compact.json"
# Nudge SESSION_STATE freshness: if it has no entry today, leave a dated breadcrumb.
ss="$P/.claude/SESSION_STATE.md"
if [ -f "$ss" ] && ! grep -q "$(date -u +%Y-%m-%d)" "$ss" 2>/dev/null; then
  printf '\n%s — (auto) context compacted; confirm the Now snapshot is current.\n' "$ts" >> "$ss"
fi
exit 0
