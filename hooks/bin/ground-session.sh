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

cat <<'DIRECTIVE'
=== workbench prime directive: forward motion ===
You do not stop, and you do not ask permission to continue. If you can see the next
step, take it — then report what you DID, not what you're "ready" to do. Ending a turn
with "want me to…?", "shall I proceed?", "is this a good place to stop?", "let me know
if you'd like…", or "when you're ready" while you already have a plan is a DEFECT:
delete the question and do the work. Offering options is fine; stopping the turn to
wait for an answer you could reasonably assume is not.

End a turn ONLY when one of these is true:
 • the work is genuinely complete AND verified with evidence, or
 • you are physically blocked (needs a device/login/credential only the human has), or
 • you hit a decision-fork that is expensive to reverse (architecture, data schema,
   crypto/security/privacy, a destructive or irreversible action) — and even then you
   write it to decisions/ and KEEP BUILDING another track rather than idling.

Pick the sensible default, act, and state what you decided. The next right thing is
almost never "ask" — it is "do, then tell."
DIRECTIVE
echo ""
echo "=== workbench operating brief: ${name:-this project} ==="
echo "This project uses workbench. Embody .claude/SOUL.md; follow the loop in CLAUDE.md."
echo "A task is NOT done until verified/ with evidence. 'In review' is not done."

# the loop charter — the stable north star, re-injected every session so compaction
# can never summarize the goal away. Pinned near the top (a context edge), bounded.
_charter="$(il_cfg_dir "$P")/loop-charter.md"
if [ -f "$_charter" ]; then
  echo ""
  echo "=== loop charter (the north star — re-read it, do not drift) ==="
  sed -n '1,40p' "$_charter"
fi
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

# Refresh producers (they file keyed, deduped suggestions as a side effect), then
# surface the top open suggestions — the recommend-only "here's what I'd consider"
# the loop opens with instead of silence. Everything routes through the one surface.
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ]; then
  [ -x "$CLAUDE_PLUGIN_ROOT/scripts/graduate.sh" ] && bash "$CLAUDE_PLUGIN_ROOT/scripts/graduate.sh" "$P" >/dev/null 2>&1
  if [ -x "$CLAUDE_PLUGIN_ROOT/scripts/suggest.sh" ]; then
    sug="$(bash "$CLAUDE_PLUGIN_ROOT/scripts/suggest.sh" top 3 --target "$P" 2>/dev/null)"
    [ -n "$sug" ] && { echo ""; printf '%s\n' "$sug"; }
  fi
fi
exit 0
