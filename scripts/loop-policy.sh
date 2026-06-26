#!/usr/bin/env bash
# Workbench loop-autonomy resolver. Prints the loop autonomy mode for a project:
# dial_overrides.loop_autonomy wins if set, else the level preset.
set -uo pipefail
P="${1:-$PWD}"
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; . "$SELF/lib.sh"; . "$SELF/levels.sh"
mode="$(wb_dial "$P" loop_autonomy)"
printf '%s\n' "${mode:-auto-continue}"
