#!/usr/bin/env bash
# workbench: close an epic — mirrors task-move.sh's state-rewrite shape (git mv /
# **Status:** rewrite), scoped to an epic's own status field rather than a directory
# move (epics don't live in per-stage subdirectories, so there is nothing to `mv`).
#
# Every other lifecycle transition in this plugin is gated (verify-gate.sh /
# gate-integrity.sh on task-move.sh); epics previously had none — an epic could be
# hand-edited to "done" while its child tasks were still mid-flight. This script is
# the enforcement: it scans .claude/tasks/**/*.md for every task carrying
# `**Epic:** <id>`, resolves this project's TERMINAL stages from its configured level
# (wb_level_lifecycle — solo/pair have no 'shipped'; 'staged'/'release-candidate' are
# deploy-gated waypoints, not terminal), and refuses to close unless every linked task
# has reached one of those terminal stages. No override flag — see the task's own
# instructions: "do not force it."
#
# Usage: epic-close.sh <epic-id> [--target DIR]
set -euo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SELF_DIR/lib.sh"
. "$SELF_DIR/levels.sh"

ID="" TARGET="$PWD"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --target) [ "$#" -ge 2 ] || { echo "epic-close.sh: --target requires a value" >&2; exit 64; }; TARGET="$2"; shift 2 ;;
    -*) echo "epic-close.sh: unknown flag '$1'" >&2; exit 64 ;;
    *)  if [ -z "$ID" ]; then ID="$1"; else echo "epic-close.sh: too many positional args" >&2; exit 64; fi; shift ;;
  esac
done
[ -n "$ID" ] || { echo "epic-close.sh: usage: epic-close.sh <epic-id> [--target DIR]" >&2; exit 64; }
TARGET="${TARGET%/}"; [ -n "$TARGET" ] || TARGET="/"

E="$TARGET/.claude/epics"
[ -d "$E" ] || { echo "epic-close.sh: no $E (this project's level may not use epics — see /workbench:level)" >&2; exit 1; }
src="$(find "$E" -maxdepth 1 -type f \( -name "$ID-*.md" -o -name "$ID.md" \) 2>/dev/null | sort | head -1)"
[ -n "$src" ] || { echo "epic-close.sh: no epic file for id $ID under $E" >&2; exit 1; }

cur_status="$(grep -m1 -E '^\*\*Status:\*\*' "$src" | sed 's/^\*\*Status:\*\* *//' | tr -d ' \r' || true)"
if [ "$cur_status" = "done" ]; then
  echo "epic-close.sh: epic $ID is already done ($src)"
  exit 0
fi

T="$TARGET/.claude/tasks"
[ -d "$T" ] || { echo "epic-close.sh: no $T (not a workbench project?)" >&2; exit 1; }

# terminal states for this project's level: intersect {verified, shipped} with what
# wb_level_lifecycle actually lists for the configured level (falls open to both if
# the level is unset/unknown, so the check never silently no-ops).
_cfg="$(il_cfg_dir "$TARGET")/config.json"
LEVEL=""
[ -f "$_cfg" ] && LEVEL="$(sed -n 's/.*"level"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$_cfg" | head -1)"
level_states="$(wb_level_lifecycle "${LEVEL:-solo}" 2>/dev/null || true)"
terminal=""
for s in verified shipped; do
  for ls in $level_states; do
    [ "$s" = "$ls" ] && terminal="$terminal $s"
  done
done
[ -n "$terminal" ] || terminal=" verified shipped"

# scan every task file for a back-reference to this epic (same shape mc.sh's rollup
# already uses: **Epic:** <id> not immediately followed by another digit)
linked_files="$(grep -rlE "^\*\*Epic:\*\* *${ID}([^0-9]|\$)" "$T" 2>/dev/null | sort || true)"

nlinked=0 nblocking=0 blocking_list=""
if [ -n "$linked_files" ]; then
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    nlinked=$((nlinked + 1))
    stage="$(basename "$(dirname "$f")")"
    is_terminal=0
    for s in $terminal; do
      [ "$stage" = "$s" ] && { is_terminal=1; break; }
    done
    if [ "$is_terminal" != 1 ]; then
      nblocking=$((nblocking + 1))
      tid="$(basename "$f" .md | grep -oE '^[0-9]{4,}' || true)"
      [ -n "$tid" ] || tid="$(basename "$f")"
      blocking_list="${blocking_list}${blocking_list:+, }${tid} (${stage})"
    fi
  done <<EOF
$linked_files
EOF
fi

if [ "$nblocking" -gt 0 ]; then
  echo "epic-close: refusing to close $ID — $nblocking of $nlinked linked task(s) are not yet terminal:" >&2
  echo "  $blocking_list" >&2
  echo "epic-close: terminal states for this project (level '${LEVEL:-solo}'):$terminal" >&2
  exit 3
fi

sed -i.bak -E "s/^\*\*Status:\*\* .*/**Status:** done/" "$src" && rm -f "$src.bak"
if ! grep -q '^\*\*Status:\*\*' "$src"; then
  { head -1 "$src"; echo "**Status:** done"; tail -n +2 "$src"; } > "$src.tmp" && mv "$src.tmp" "$src"
fi

closed_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf '\n_Closed %s — %d/%d linked task(s) verified terminal._\n' "$closed_at" "$nlinked" "$nlinked" >> "$src"

echo "workbench: closed epic $ID -> done  ($src)  ($nlinked linked task(s), all terminal)"
