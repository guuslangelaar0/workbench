#!/usr/bin/env bash
# workbench SUGGESTION SURFACE (recommend-only). The loop has three response modes:
# auto-act (only carved exceptions: bugs auto-file, lifecycle moves), block→decisions/
# (only an expensive, irreversible fork), and SUGGEST (everything else). Most operational
# intelligence belongs in suggest — non-blocking recommendations the human acts on when
# they like. This is the home for them: producers (graduate, arch-drift, budget, the
# anti-gaming guard, the in-review cap, …) file keyed suggestions; the human reads them
# via /workbench:suggest, the SessionStart brief, and /workbench:mc.
#
# A suggestion NEVER mutates the project. `act` PRINTS the command to run; it does not run it.
#
# Storage: <cfg>/suggestions/<key>.suggest — greppable key=value lines (NOT json):
#   severity=info|recommend|warn  title=…  why=…  how=…  source=…  created=<epoch>  status=open|acted|dismissed
# The filename key is the dedup unit: a producer re-emitting the same key is a no-op, so
# the same recommendation never piles up (and a dismissed one is not resurrected).
#
# Usage:
#   suggest.sh add --key K --severity S --title T [--why W] [--how H] [--source SRC] [--target DIR]
#   suggest.sh list [--all] [--target DIR]        ranked warn>recommend>info; open-only unless --all
#   suggest.sh top  [N] [--target DIR]            compact one-liners for the brief (default 3)
#   suggest.sh act     <key> [--target DIR]       print the 'how' command + mark status=acted
#   suggest.sh dismiss <key> [--target DIR]       mark status=dismissed (won't resurface)
#   suggest.sh clear   <key> [--target DIR]       remove the suggestion file
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SELF_DIR/lib.sh"

sug_dir()  { printf '%s\n' "$(il_cfg_dir "$1")/suggestions"; }
sug_file() { printf '%s\n' "$(sug_dir "$1")/$2.suggest"; }

# one-line sanitize: collapse newlines/tabs to spaces so a value stays on its own line
_clean() { printf '%s' "$1" | tr '\n\t' '  '; }
_get()   { [ -f "$1" ] || return 0; sed -n "s/^$2=//p" "$1" | head -1; }

# numeric rank for severity (higher = more urgent), for sorting + glyph
_rank()  { case "$1" in warn) echo 3 ;; recommend) echo 2 ;; *) echo 1 ;; esac; }
_glyph() { case "$1" in warn) printf '!' ;; recommend) printf '▲' ;; *) printf '·' ;; esac; }

CMD="${1:-}"; [ "$#" -gt 0 ] && shift
KEY="" SEV="recommend" TITLE="" WHY="" HOW="" SOURCE="" TARGET="$PWD" ALL=0
POS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --key)      KEY="$2"; shift 2 ;;
    --severity) SEV="$2"; shift 2 ;;
    --title)    TITLE="$2"; shift 2 ;;
    --why)      WHY="$2"; shift 2 ;;
    --how)      HOW="$2"; shift 2 ;;
    --source)   SOURCE="$2"; shift 2 ;;
    --target)   TARGET="$2"; shift 2 ;;
    --all)      ALL=1; shift ;;
    -*)         echo "suggest.sh: unknown flag '$1'" >&2; exit 64 ;;
    *)          POS+=("$1"); shift ;;
  esac
done
TARGET="${TARGET%/}"; [ -n "$TARGET" ] || TARGET="/"

case "$CMD" in
  add)
    [ -n "$KEY" ]   || { echo "suggest.sh: add requires --key" >&2; exit 64; }
    [ -n "$TITLE" ] || { echo "suggest.sh: add requires --title" >&2; exit 64; }
    case "$SEV" in info|recommend|warn) ;; *) echo "suggest.sh: --severity must be info|recommend|warn" >&2; exit 64 ;; esac
    KEY="$(printf '%s' "$KEY" | tr -c 'A-Za-z0-9._-' '-')"   # filesystem-safe key
    dir="$(sug_dir "$TARGET")"; mkdir -p "$dir"
    f="$(sug_file "$TARGET" "$KEY")"
    # dedup: an existing suggestion (any status) is left untouched — never nag, never resurrect.
    [ -f "$f" ] && { echo "suggest: $KEY already filed (no-op)"; exit 0; }
    { printf 'severity=%s\n' "$SEV"
      printf 'title=%s\n'    "$(_clean "$TITLE")"
      printf 'why=%s\n'      "$(_clean "$WHY")"
      printf 'how=%s\n'      "$(_clean "$HOW")"
      printf 'source=%s\n'   "$(_clean "$SOURCE")"
      printf 'created=%s\n'  "$(date +%s)"
      printf 'status=%s\n'   open
    } > "$f"
    echo "suggest: filed $KEY ($SEV)"
    ;;

  list|top)
    n=0; [ "$CMD" = top ] && { n="${POS[0]:-3}"; case "$n" in ''|*[!0-9]*) n=3 ;; esac; }
    dir="$(sug_dir "$TARGET")"
    [ -d "$dir" ] || { [ "$CMD" = list ] && echo "No suggestions."; exit 0; }
    # build "rank<TAB>created<TAB>key<TAB>sev<TAB>title<TAB>why<TAB>how" then sort
    rows=""
    for f in "$dir"/*.suggest; do
      [ -e "$f" ] || continue
      st="$(_get "$f" status)"; [ "$ALL" = 1 ] || [ "$st" = open ] || continue
      sev="$(_get "$f" severity)"; key="$(basename "$f" .suggest)"
      rows="${rows}$(_rank "$sev")	$(_get "$f" created)	$key	$sev	$(_get "$f" title)	$(_get "$f" why)	$(_get "$f" how)
"
    done
    [ -n "$rows" ] || { [ "$CMD" = list ] && echo "No suggestions."; exit 0; }
    # sort by rank desc, then created desc (newest urgent first)
    sorted="$(printf '%s' "$rows" | sort -t$'\t' -k1,1nr -k2,2nr)"
    [ "$CMD" = top ] && sorted="$(printf '%s\n' "$sorted" | head -n "$n")"
    if [ "$CMD" = top ]; then
      echo "workbench suggestions (top $n — recommend-only · /workbench:suggest):"
      while IFS=$'\t' read -r rank created key sev title why how; do
        [ -n "$key" ] || continue
        printf '  %s %-22s %s\n' "$(_glyph "$sev")" "$key" "$title"
      done <<< "$sorted"
    else
      echo "workbench suggestions (recommend-only — nothing changes without you):"
      echo ""
      while IFS=$'\t' read -r rank created key sev title why how; do
        [ -n "$key" ] || continue
        printf '%s [%s] %s\n' "$(_glyph "$sev")" "$sev" "$title"
        printf '    key: %s\n' "$key"
        [ -n "$why" ] && printf '    why: %s\n' "$why"
        [ -n "$how" ] && printf '    how: %s\n' "$how"
        echo ""
      done <<< "$sorted"
      echo "act:  /workbench:suggest act <key>   ·   dismiss: /workbench:suggest dismiss <key>"
    fi
    ;;

  act)
    key="${POS[0]:-}"; [ -n "$key" ] || { echo "suggest.sh: act requires <key>" >&2; exit 64; }
    f="$(sug_file "$TARGET" "$key")"
    [ -f "$f" ] || { echo "suggest: no suggestion '$key'" >&2; exit 1; }
    how="$(_get "$f" how)"
    echo "${key}: $(_get "$f" title)"
    if [ -n "$how" ]; then echo "run this (recommend-only — not auto-run):"; echo "  $how"
    else echo "(no command attached — see /workbench:suggest list for the why)"; fi
    sed -i.bak 's/^status=.*/status=acted/' "$f" 2>/dev/null && rm -f "$f.bak"
    ;;

  dismiss)
    key="${POS[0]:-}"; [ -n "$key" ] || { echo "suggest.sh: dismiss requires <key>" >&2; exit 64; }
    f="$(sug_file "$TARGET" "$key")"
    [ -f "$f" ] || { echo "suggest: no suggestion '$key'" >&2; exit 1; }
    sed -i.bak 's/^status=.*/status=dismissed/' "$f" 2>/dev/null && rm -f "$f.bak"
    echo "suggest: dismissed $key (won't resurface)"
    ;;

  clear)
    key="${POS[0]:-}"; [ -n "$key" ] || { echo "suggest.sh: clear requires <key>" >&2; exit 64; }
    rm -f "$(sug_file "$TARGET" "$key")"
    echo "suggest: cleared $key"
    ;;

  ""|-h|--help|help)
    sed -n '2,28p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
    [ -n "$CMD" ] && exit 0 || exit 64
    ;;

  *)
    echo "suggest.sh: unknown subcommand '$CMD' (add|list|top|act|dismiss|clear)" >&2
    exit 64
    ;;
esac
exit 0
