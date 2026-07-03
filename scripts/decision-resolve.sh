#!/usr/bin/env bash
# workbench: resolve a decision — append the human's outcome (with a resolved-at
# timestamp) as a `## Resolution` section, then hand off to task-move.sh for the
# actual git-mv + **Status:** rewrite. Same shape as every other lifecycle
# transition in this plugin: the file lives in git, the status field mirrors the
# directory, task-move.sh does the move.
#
# Default destination is backlog/ — resolving a decision means the human answered
# the fork, so the now-unblocked work re-enters the normal flow. A decision file can
# override this with a `**Resolution-target:**` field in its own body (any valid
# stage for this project's level); `--to STATE` on the command line wins over both.
#
# Usage: decision-resolve.sh <id> [--outcome "<text>"] [--to STATE] [--target DIR]
set -euo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SELF_DIR/lib.sh"

ID="" TARGET="$PWD" OUTCOME="" TO_OVERRIDE=""
need_arg() { [ "$#" -ge 2 ] || { echo "decision-resolve.sh: $1 requires a value" >&2; exit 64; }; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --outcome) need_arg "$@"; OUTCOME="$2"; shift 2 ;;
    --to)      need_arg "$@"; TO_OVERRIDE="$2"; shift 2 ;;
    --target)  need_arg "$@"; TARGET="$2"; shift 2 ;;
    -*) echo "decision-resolve.sh: unknown flag '$1'" >&2; exit 64 ;;
    *)  if [ -z "$ID" ]; then ID="$1"; else echo "decision-resolve.sh: too many positional args" >&2; exit 64; fi; shift ;;
  esac
done
[ -n "$ID" ] || { echo "decision-resolve.sh: usage: decision-resolve.sh <id> [--outcome \"<text>\"] [--to STATE] [--target DIR]" >&2; exit 64; }
TARGET="${TARGET%/}"; [ -n "$TARGET" ] || TARGET="/"

D="$TARGET/.claude/tasks/decisions"
[ -d "$D" ] || { echo "decision-resolve.sh: no $D — nothing to resolve" >&2; exit 1; }
src="$(find "$D" -maxdepth 1 -type f \( -name "$ID-*.md" -o -name "$ID.md" \) 2>/dev/null | sort | head -1)"
[ -n "$src" ] || { echo "decision-resolve.sh: no decision file for id $ID under $D" >&2; exit 1; }

# resolution target: --to wins, then a file-declared **Resolution-target:** override,
# else the default 'backlog' so the now-unblocked work re-enters the normal flow.
TO="$TO_OVERRIDE"
if [ -z "$TO" ]; then
  TO="$(grep -m1 -E '^\*\*Resolution-target:\*\*' "$src" | sed 's/^\*\*Resolution-target:\*\* *//' | tr -d ' \r' || true)"
fi
[ -n "$TO" ] || TO="backlog"

RESOLVED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
{
  printf '\n## Resolution\n'
  printf '**Resolved:** %s\n' "$RESOLVED_AT"
  if [ -n "$OUTCOME" ]; then
    printf '**Outcome:** %s\n' "$OUTCOME"
  else
    printf '**Outcome:** (no outcome text recorded)\n'
  fi
} >> "$src"

"$SELF_DIR/task-move.sh" "$ID" "$TO" --target "$TARGET"
echo "workbench: resolved decision $ID -> $TO"
