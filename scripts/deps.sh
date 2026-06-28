#!/usr/bin/env bash
# workbench TASK DEPENDENCY GRAPH. Tasks declare `**Blocked-by:** <ids>` (space/comma-
# separated). A task is READY when every id it's blocked by is done (in verified/ or
# shipped/). The orchestration picker consults this so it never grabs work whose
# prerequisite isn't finished. Pure bash; reads task files directly.
#
# Usage:
#   deps.sh status <id> [--target DIR]    -> "ready" or "blocked-by: <unmet ids>"
#   deps.sh ready  [--target DIR]         -> backlog ids whose deps are all met (pickable)
#   deps.sh blocked [--target DIR]        -> non-done tasks with unmet deps + what's missing
#   deps.sh cycles [--target DIR]         -> report any dependency cycle (exit 3 if found)
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SELF_DIR/lib.sh"

CMD="${1:-}"; [ "$#" -gt 0 ] && shift
TARGET="$PWD"; POS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --target) TARGET="$2"; shift 2 ;;
    -*) echo "deps.sh: unknown flag '$1'" >&2; exit 64 ;;
    *)  POS+=("$1"); shift ;;
  esac
done
TARGET="${TARGET%/}"; [ -n "$TARGET" ] || TARGET="/"
T="$TARGET/.claude/tasks"
[ -d "$T" ] || { echo "deps.sh: no $T" >&2; exit 1; }

_file() { find "$T" -maxdepth 2 -type f \( -name "$1-*.md" -o -name "$1.md" \) 2>/dev/null | sort | head -1; }
_dir()  { local f; f="$(_file "$1")"; [ -n "$f" ] && basename "$(dirname "$f")" || echo ""; }
_done() { case "$(_dir "$1")" in verified|shipped) return 0 ;; *) return 1 ;; esac; }
# parse Blocked-by ids (numbers only); "(none)"/empty -> nothing
_deps() {
  local f; f="$(_file "$1")"; [ -n "$f" ] || return 0
  sed -n 's/^\*\*Blocked-by:\*\*[[:space:]]*//p' "$f" | head -1 \
    | grep -oE '[0-9]{3,}' | sort -u
}
_unmet() { local d out=""; for d in $(_deps "$1"); do _done "$d" || out="${out:+$out }$d"; done; printf '%s' "$out"; }

case "$CMD" in
  status)
    id="${POS[0]:-}"; [ -n "$id" ] || { echo "deps.sh: status requires <id>" >&2; exit 64; }
    u="$(_unmet "$id")"
    if [ -z "$u" ]; then echo "ready"; else echo "blocked-by: $u"; fi
    ;;
  ready)
    for f in "$T"/backlog/*.md; do
      [ -e "$f" ] || continue
      id="$(basename "$f" .md | grep -oE '^[0-9]{3,}')"; [ -n "$id" ] || continue
      [ -z "$(_unmet "$id")" ] && echo "$id"
    done
    ;;
  blocked)
    found=0
    for f in $(find "$T" -maxdepth 2 -type f -name '*.md' 2>/dev/null | sort); do
      id="$(basename "$f" .md | grep -oE '^[0-9]{3,}')"; [ -n "$id" ] || continue
      _done "$id" && continue
      u="$(_unmet "$id")"
      [ -n "$u" ] && { printf '%s blocked-by: %s\n' "$id" "$u"; found=1; }
    done
    [ "$found" = 0 ] && echo "(no blocked tasks)"
    ;;
  cycles)
    # DFS from each task following Blocked-by edges; a node seen twice on one path = cycle.
    found=0
    walk() { # <start> <current> <path>
      local start="$1" cur="$2" path="$3" d
      for d in $(_deps "$cur"); do
        case " $path " in *" $d "*)
          if [ "$d" = "$start" ]; then echo "cycle: $path -> $d"; found=1; fi
          continue ;;
        esac
        walk "$start" "$d" "$path $d"
      done
    }
    for f in $(find "$T" -maxdepth 2 -type f -name '*.md' 2>/dev/null | sort); do
      id="$(basename "$f" .md | grep -oE '^[0-9]{3,}')"; [ -n "$id" ] || continue
      walk "$id" "$id" "$id"
    done
    [ "$found" = 0 ] && { echo "(no cycles)"; exit 0; }
    exit 3
    ;;
  ""|-h|--help|help)
    sed -n '2,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
    [ -n "$CMD" ] && exit 0 || exit 64 ;;
  *)
    echo "deps.sh: unknown subcommand '$CMD' (status|ready|blocked|cycles)" >&2; exit 64 ;;
esac
exit 0
