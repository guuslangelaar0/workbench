#!/usr/bin/env bash
# workbench: move a task between lifecycle states (git mv when tracked, else mv) and
# rewrite its **Status:** field to match. Deterministic + python-free. The lead
# runs this for all lifecycle transitions (/workbench:dispatch, /workbench:verify).
#
# Usage: task-move.sh <id> <to-state> [--target DIR]
set -euo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SELF_DIR/lib.sh"
. "$SELF_DIR/levels.sh"

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

# validate the requested stage against the project's configured level lifecycle
_cfg="$(il_cfg_dir "$TARGET")/config.json"
if [ -f "$_cfg" ]; then
  LEVEL="$(sed -n 's/.*"level"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$_cfg" | head -1)"
  if [ -n "$LEVEL" ]; then
    _valid="$(wb_level_lifecycle "$LEVEL" 2>/dev/null)" || true
    if [ -n "$_valid" ]; then
      _found=0
      for _s in $_valid; do
        [ "$_s" = "$TO" ] && { _found=1; break; }
      done
      if [ "$_found" = 0 ]; then
        echo "task-move: '$TO' is not a stage at level '$LEVEL' (valid: $_valid)" >&2
        exit 64
      fi
    fi
  fi
fi

T="$TARGET/.claude/tasks"
[ -d "$T" ] || { echo "task-move.sh: no $T (not a workbench project?)" >&2; exit 1; }
src="$(find "$T" -maxdepth 2 -type f \( -name "$ID-*.md" -o -name "$ID.md" \) 2>/dev/null | sort | head -1)"
[ -n "$src" ] || { echo "task-move.sh: no task file for id $ID under $T" >&2; exit 1; }

# verification-contract gate: a move into a "done" stage requires real acceptance
# criteria + captured evidence. verify-gate.sh is level-scaled (enforces at crew/fleet,
# advisory at solo/pair) and fails open. Override the rare legit case with WB_SKIP_VERIFY_GATE=1.
case "$TO" in
  verified|staged|shipped)
    if [ "${WB_SKIP_VERIFY_GATE:-0}" != 1 ] && [ -x "$SELF_DIR/verify-gate.sh" ]; then
      if ! "$SELF_DIR/verify-gate.sh" "$src" --target "$TARGET" >/dev/null; then
        echo "task-move: refusing to move $ID to '$TO' — verification contract unmet (see above)." >&2
        echo "  Fill in real acceptance criteria + the '## Verification evidence' section, or set WB_SKIP_VERIFY_GATE=1 to override." >&2
        exit 3
      fi
    fi
    # Anti-gaming guard — ADVISORY here (the working-tree diff at move time is unreliable;
    # real enforcement lives in /workbench:verify with a proper commit range). Best-effort:
    # it scans `git diff HEAD`, files a warn suggestion on anything suspicious, never blocks.
    if [ "${WB_SKIP_VERIFY_GATE:-0}" != 1 ] && [ -x "$SELF_DIR/gate-integrity.sh" ]; then
      "$SELF_DIR/gate-integrity.sh" --task "$src" --key "gaming-$ID" --target "$TARGET" >/dev/null 2>&1 || true
    fi
    ;;
esac

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
echo "workbench: moved $ID  $from -> $TO  ($dest)"
