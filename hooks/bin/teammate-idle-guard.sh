#!/usr/bin/env bash
# workbench TeammateIdle hook — secondary verification gate.
#
# Before a teammate goes idle, refuse if it left a task in in-review/ whose
# verification contract is unmet (no real acceptance criteria, or no captured
# evidence). Delegates the judgement to verify-gate.sh, which is level-scaled
# (enforces at crew/fleet, advisory at solo/pair).
#
# The airtight gate is task-move.sh (every ->verified transition); this hook just
# nudges a teammate not to down tools with unverifiable work sitting in review.
#
# FAILS OPEN: never blocks a non-workbench session, and never errors a turn.
#   exit 2 -> feedback shown to the teammate, keep it working
#   exit 0 -> allow idle
set -uo pipefail
cat >/dev/null 2>&1 || true   # drain the hook's stdin payload; we judge from disk, not it

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SELF_DIR/../.." && pwd)"
GATE="$PLUGIN_ROOT/scripts/verify-gate.sh"
PROJECT="${CLAUDE_PROJECT_DIR:-$PWD}"
. "$PLUGIN_ROOT/scripts/lib.sh" 2>/dev/null || exit 0
[ -f "$(il_cfg_dir "$PROJECT")/config.json" ] || exit 0
il_hooks_enabled "$PROJECT" || exit 0
REVIEW="$PROJECT/.claude/tasks/in-review"

# fail open: not a workbench project, no gate, or nothing in review
[ -x "$GATE" ] && [ -d "$REVIEW" ] || exit 0

blocked=""
for f in "$REVIEW"/*.md; do
  [ -e "$f" ] || continue
  # verify-gate exits 3 only when the level ENFORCES and the contract is unmet
  if out="$("$GATE" "$f" --target "$PROJECT" 2>&1 >/dev/null)"; then
    : # PASS or advisory -> don't block on this file
  else
    blocked="${blocked}
  - $(basename "$f"): ${out#verify-gate: }"
  fi
done

if [ -n "$blocked" ]; then
  printf 'Before going idle: these in-review tasks have an unmet verification contract:%s\nCapture acceptance criteria + the "## Verification evidence" section (or run /workbench:verify) before stopping.\n' "$blocked" >&2
  exit 2
fi
exit 0
