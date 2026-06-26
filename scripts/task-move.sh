#!/usr/bin/env bash
# initlab: move a task between lifecycle states (git mv when tracked, else mv) and
# rewrite its **Status:** field to match. Deterministic + python-free. The lead
# runs this for all lifecycle transitions (/initlab:dispatch, /initlab:verify).
#
# Usage: task-move.sh <id> <to-state> [--target DIR]
set -euo pipefail
ID="" TO="" TARGET="$PWD"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --target) [ "$#" -ge 2 ] || { echo "task-move.sh: --target requires a value" >&2; exit 64; }; TARGET="$2"; shift 2 ;;
    -*) echo "task-move.sh: unknown flag '$1'" >&2; exit 64 ;;
    *)  if [ -z "$ID" ]; then ID="$1"; elif [ -z "$TO" ]; then TO="$1";
        else echo "task-move.sh: too many positional args" >&2; exit 64; fi; shift ;;
  esac
done
[ -n "$ID" ] && [ -n "$TO" ] || { echo "task-move.sh: usage: task-move.sh <id> <to-state> [--target DIR]" >&2; exit 64; }
TARGET="${TARGET%/}"; [ -n "$TARGET" ] || TARGET="/"

T="$TARGET/.claude/tasks"
[ -d "$T" ] || { echo "task-move.sh: no $T (not an initlab project?)" >&2; exit 1; }
src="$(find "$T" -maxdepth 2 -type f \( -name "$ID-*.md" -o -name "$ID.md" \) 2>/dev/null | sort | head -1)"
[ -n "$src" ] || { echo "task-move.sh: no task file for id $ID under $T" >&2; exit 1; }

mkdir -p "$T/$TO"
dest="$T/$TO/$(basename "$src")"
if [ "$src" = "$dest" ]; then echo "task-move.sh: $ID already in $TO"; exit 0; fi

rel="${src#"$TARGET"/}"; reldest="${dest#"$TARGET"/}"
if command -v git >/dev/null 2>&1 \
   && git -C "$TARGET" rev-parse --git-dir >/dev/null 2>&1 \
   && git -C "$TARGET" ls-files --error-unmatch "$rel" >/dev/null 2>&1; then
  git -C "$TARGET" mv "$rel" "$reldest"
else
  mv "$src" "$dest"
fi

# rewrite the Status field in place (portable: -i.bak works on GNU + BSD sed)
sed -i.bak -E "s/^\*\*Status:\*\* .*/**Status:** $TO/" "$dest" && rm -f "$dest.bak"

# if the task had no Status line, inject one after the title so the body mirrors the directory
if ! grep -q '^\*\*Status:\*\*' "$dest"; then
  { head -1 "$dest"; echo "**Status:** $TO"; tail -n +2 "$dest"; } > "$dest.tmp" && mv "$dest.tmp" "$dest"
  echo "task-move.sh: note — task $ID had no **Status:** line; inserted one" >&2
fi

from="$(basename "$(dirname "$src")")"
echo "initlab: moved $ID  $from -> $TO  ($dest)"
