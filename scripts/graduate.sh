#!/usr/bin/env bash
# Workbench graduation detector (recommend-only). Reads project signals and
# prints a single recommendation block if the project has outgrown its level,
# else nothing. Always exits 0 — it advises, it never acts.
set -uo pipefail
P="${1:-$PWD}"
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; . "$SELF/lib.sh"; . "$SELF/levels.sh"
CFG="$(il_cfg_dir "$P")/config.json"; [ -f "$CFG" ] || exit 0
level="$(sed -n 's/.*"level"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$CFG" | head -1)"
idx="$(wb_level_index "$level" 2>/dev/null || echo 0)"

signals=""
add() { signals="${signals:+$signals; }$1"; }
# observed signals
tags="$(git -C "$P" tag 2>/dev/null | grep -c . || echo 0)"
[ "${tags:-0}" -gt 0 ] && [ "$idx" -lt 2 ] && add "release tag(s) present"
committers="$(git -C "$P" log --format='%ae' 2>/dev/null | sort -u | grep -c . || echo 0)"
[ "${committers:-0}" -gt 1 ] && [ "$idx" -lt 1 ] && add "more than one committer"
ir="$(ls -1 "$P/.claude/tasks/in-review" 2>/dev/null | grep -c '\.md$' || echo 0)"
cap="$(sed -n 's/.*"in_review_cap"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' "$CFG" | head -1)"; [ -n "$cap" ] || cap=10
[ "${ir:-0}" -ge "$cap" ] && add "in-review cap reached"
repos="$(ls -d "$P"/repos/*/ 2>/dev/null | grep -c . || echo 0)"
[ "${repos:-0}" -gt 1 ] && [ "$idx" -lt 2 ] && add "multiple repos"

[ -z "$signals" ] && exit 0
next="$(wb_levels | tr ' ' '\n' | sed -n "$((idx+2))p")"; [ -n "$next" ] || exit 0
echo "▲ workbench: consider graduating ${level} → ${next}"
echo "  signals: $signals"
echo "  run /workbench:level up to see exactly which dials change (recommend-only — nothing changes without you)."
exit 0
