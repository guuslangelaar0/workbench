#!/usr/bin/env bash
# workbench SessionStart re-ground hook. Prints a disk-derived operating brief to
# stdout (Claude Code injects SessionStart stdout as context). No-ops unless this
# is a workbench project. Keep output well under the ~10k char cap.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SELF_DIR/../../scripts/lib.sh"
P="${CLAUDE_PROJECT_DIR:-$PWD}"
_cfg="$(il_cfg_dir "$P")/config.json"
[ -f "$_cfg" ] || exit 0
T="$P/.claude/tasks"

name="$(sed -n 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$_cfg" | head -1)"
count() { ls -1 "$T/$1" 2>/dev/null | grep -c '\.md$' || true; }
cap="$(sed -n 's/.*"in_review_cap"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' "$_cfg" | head -1)"; [ -n "$cap" ] || cap=10

echo "=== workbench operating brief: ${name:-this project} ==="
echo "This project uses workbench. Embody .claude/SOUL.md; follow the loop in CLAUDE.md."
echo "A task is NOT done until verified/ with evidence. 'In review' is not done."
echo ""
echo "Tasks: backlog $(count backlog) · in-development $(count in-development) · in-review $(count in-review)/$cap · verified $(count verified) · decisions $(count decisions)"

inflight="$(ls -1 "$T/in-development" 2>/dev/null | grep '\.md$' | sed 's/\.md$//' | head -8)"
[ -n "$inflight" ] && { echo ""; echo "In development:"; printf '  %s\n' $inflight; }

decisions="$(ls -1 "$T/decisions" 2>/dev/null | grep '\.md$' | sed 's/\.md$//' | head -8)"
[ -n "$decisions" ] && { echo ""; echo "Decisions awaiting you:"; printf '  %s\n' $decisions; }

ir="$(count in-review)"; [ "${ir:-0}" -ge "$cap" ] 2>/dev/null && echo "" && echo "⚠ in-review cap reached ($ir/$cap) — drain to verification before new work."

if [ -f "$P/.claude/SESSION_STATE.md" ]; then
  snap="$(sed -n '/^## Now/,/^## /p' "$P/.claude/SESSION_STATE.md" | sed '/^## /d;/^$/d' | head -8 | sed 's/^/  /')"
  [ -n "$snap" ] && { echo ""; echo "SESSION_STATE 'Now' snapshot:"; printf '%s\n' "$snap"; }
fi

if [ -x "$P/scripts/coord/wb-coord" ]; then
  # Anchor presence on this project (CLAUDE_PROJECT_DIR), not the cwd — otherwise
  # wb-coord re-derives the root from wherever the shell happens to be and would
  # surface sessions from an unrelated repo.
  echo ""; echo "Other live sessions:"; WB_WORKSPACE_ROOT="$P" "$P/scripts/coord/wb-coord" who 2>/dev/null | sed 's/^/  /' | head -6
fi
exit 0
