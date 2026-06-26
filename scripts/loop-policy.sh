#!/usr/bin/env bash
# Workbench loop-autonomy resolver. Prints the loop autonomy mode for a project:
# an explicit dials.loop_autonomy override wins, else the level preset.
set -uo pipefail
P="${1:-$PWD}"
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; . "$SELF/lib.sh"; . "$SELF/levels.sh"
CFG="$(il_cfg_dir "$P")/config.json"
mode="$(sed -n 's/.*"loop_autonomy"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$CFG" 2>/dev/null | head -1)"
if [ -z "$mode" ]; then
  level="$(sed -n 's/.*"level"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$CFG" 2>/dev/null | head -1)"
  mode="$(wb_level_dials "${level:-solo}" 2>/dev/null | sed -n 's/^loop_autonomy=//p')"
fi
printf '%s\n' "${mode:-auto-continue}"
