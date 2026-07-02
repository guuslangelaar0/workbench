#!/usr/bin/env bash
# workbench EVOLUTION SUMMIT plumbing. A project-configurable persona panel
# (".workbench/evolution/personas.json" — N generators + exactly ONE critic)
# periodically convenes as a "summit" that (a) generates new ideas and
# (b) retrospectively audits a rotating slice of already-verified/shipped work,
# then synthesizes critic-approved survivors into normal backlog tasks. This
# script is the deterministic half: config parsing/validation, the trigger
# condition, the append-only ideas ledger, and retrospective-coverage rotation.
# The model half (convening the panel) lives in the `evolution` skill behind
# /workbench:evolve. Pure bash, no jq/python (see CONTRIBUTING.md).
#
# Layout under <cfg>/evolution/ (cfg = .workbench/, see il_cfg_dir):
#   personas.json   the roster + trigger knobs (schema: templates/schemas/personas.schema.json)
#   ideas-log.md    append-only ledger — the panel's memory across cycles
#   last-summit     epoch of the last summit start (written by record-summit)
#
# Usage:
#   evolve.sh init             [--target DIR]              scaffold roster + ledger (idempotent)
#   evolve.sh validate         [--target DIR]              check the roster (exit 2 on invalid)
#   evolve.sh roster           [--target DIR]              TSV: name<TAB>role<TAB>prompt
#   evolve.sh check            [--target DIR] [--track T]  first line: disabled | due <reason> | not-due
#   evolve.sh record-summit    [--target DIR]              stamp last-summit + ledger heading
#   evolve.sh log --persona P --idea I --disposition D [--target DIR]   append a ledger entry
#   evolve.sh audited          [--target DIR]              task ids already retrospectively audited
#   evolve.sh retro-candidates [--target DIR] [--track T] [--limit N]   oldest un-audited verified/shipped ids
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # workbench/scripts
PLUGIN_ROOT="$(cd "$SELF_DIR/.." && pwd)"                  # workbench
. "$SELF_DIR/lib.sh"

evo_dir()    { printf '%s\n' "$(il_cfg_dir "$1")/evolution"; }
evo_roster() { printf '%s\n' "$(evo_dir "$1")/personas.json"; }
evo_ledger() { printf '%s\n' "$(evo_dir "$1")/ideas-log.md"; }
evo_stamp()  { printf '%s\n' "$(evo_dir "$1")/last-summit"; }

CMD="${1:-}"; [ "$#" -gt 0 ] && shift
TARGET="$PWD" TRACK="" LIMIT="" PERSONA="" IDEA="" DISPOSITION=""
need_arg() { [ "$#" -ge 2 ] || { echo "evolve.sh: $1 requires a value" >&2; exit 64; }; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --target)      need_arg "$@"; TARGET="$2"; shift 2 ;;
    --track)       need_arg "$@"; TRACK="$2"; shift 2 ;;
    --limit)       need_arg "$@"; LIMIT="$2"; shift 2 ;;
    --persona)     need_arg "$@"; PERSONA="$2"; shift 2 ;;
    --idea)        need_arg "$@"; IDEA="$2"; shift 2 ;;
    --disposition) need_arg "$@"; DISPOSITION="$2"; shift 2 ;;
    *) echo "evolve.sh: unknown arg '$1'" >&2; exit 64 ;;
  esac
done
TARGET="${TARGET%/}"; [ -n "$TARGET" ] || TARGET="/"

# one-line sanitize (ledger entries must stay one entry = one line)
_clean() { printf '%s' "$1" | tr '\n\t' '  '; }

# --- roster parsing -----------------------------------------------------------
# Dependency-free parser for the constrained personas.json shape (see the
# schema): a flat top-level object of scalar knobs plus one "personas" array of
# flat objects with string values. Character state machine so quotes/braces
# inside prompt strings can't break it. Emits TSV:
#   knob<TAB><key><TAB><value>          (top-level scalars)
#   p<TAB><idx><TAB><key><TAB><value>   (persona fields, idx = 1-based order)
evo_parse() { # <personas.json>
  awk '
    function flush() { if (havetok) { emit(tok); havetok = 0 }; expectval = 0 }
    function emit(v) {
      gsub(/\t/, " ", v)
      if (depth == 1)      printf "knob\t%s\t%s\n", lastkey, v
      else if (depth >= 2) printf "p\t%d\t%s\t%s\n", pidx, lastkey, v
    }
    { buf = buf $0 "\n" }
    END {
      n = length(buf); depth = 0; instr = 0; esc = 0
      tok = ""; havetok = 0; lastkey = ""; expectval = 0
      pidx = 0; numtok = ""; innum = 0
      for (i = 1; i <= n; i++) {
        c = substr(buf, i, 1)
        if (instr) {
          if (esc)            { tok = tok ((c == "n" || c == "t") ? " " : c); esc = 0 }
          else if (c == "\\") { esc = 1 }
          else if (c == "\"") { instr = 0; havetok = 1 }
          else                { tok = tok c }
          continue
        }
        if (c == "\"") { instr = 1; tok = ""; continue }
        if (expectval && c ~ /[-0-9.]/) { numtok = numtok c; innum = 1; continue }
        if (innum) { emit(numtok); numtok = ""; innum = 0; expectval = 0 }
        if      (c == ":")  { if (havetok) { lastkey = tok; havetok = 0 }; expectval = 1 }
        else if (c == "{")  { depth++; if (depth == 2) pidx++; expectval = 0 }
        else if (c == "}")  { flush(); depth-- }
        else if (c == ",")  { flush() }
        else if (c == "[" || c == "]") { flush() }
      }
    }
  ' "$1"
}

_roster_tsv() { # <personas.json> -> name<TAB>role<TAB>prompt per persona
  evo_parse "$1" | awk -F'\t' '
    function out() { if (cur != "") printf "%s\t%s\t%s\n", v["name"], v["role"], v["prompt"]; split("", v) }
    $1 == "p" {
      if ($2 != cur) { out(); cur = $2 }
      v[$3] = $4
    }
    END { out() }
  '
}

_knob() { # <personas.json> <key> <default>
  local v
  v="$(evo_parse "$1" | awk -F'\t' -v k="$2" '$1 == "knob" && $2 == k { print $3; exit }')"
  printf '%s\n' "${v:-$3}"
}

_validate() { # <personas.json> -> problem lines on stdout; return 0 iff clean
  local tsv gens=0 crits=0 total=0 bad=0 name role prompt dups
  tsv="$(_roster_tsv "$1")"
  [ -n "$tsv" ] || { echo "no personas found (expected a 'personas' array of {name, role, prompt} objects)"; return 1; }
  while IFS=$'\t' read -r name role prompt; do
    [ -n "$name" ] || continue
    total=$((total + 1))
    [ -n "$prompt" ] || { echo "persona '$name' has an empty prompt"; bad=1; }
    case "$role" in
      generator) gens=$((gens + 1)) ;;
      critic)    crits=$((crits + 1)) ;;
      *) echo "persona '$name' has invalid role '$role' (must be generator|critic)"; bad=1 ;;
    esac
  done <<< "$tsv"
  dups="$(printf '%s\n' "$tsv" | cut -f1 | sort | uniq -d)"
  [ -z "$dups" ] || { echo "duplicate persona name(s): $(printf '%s' "$dups" | tr '\n' ' ')"; bad=1; }
  [ "$gens" -ge 1 ]  || { echo "roster needs at least one generator persona (found $gens)"; bad=1; }
  [ "$crits" -eq 1 ] || { echo "roster needs exactly ONE critic persona (found $crits)"; bad=1; }
  return "$bad"
}

_ensure_ledger() { # <target>
  local led; led="$(evo_ledger "$1")"
  [ -f "$led" ] && return 0
  mkdir -p "$(evo_dir "$1")"
  il_render "$PLUGIN_ROOT/templates/evolution/ideas-log.md.tmpl" "$led" \
    "CREATED=$(date -u +%Y-%m-%d)"
}

# ready backlog ids, optionally filtered to one **Track:** value
_ready_ids() { # <target> <track>
  local id f t
  bash "$SELF_DIR/deps.sh" ready --target "$1" 2>/dev/null | while read -r id; do
    [ -n "$id" ] || continue
    if [ -n "$2" ]; then
      f="$(find "$1/.claude/tasks/backlog" -maxdepth 1 -type f \( -name "$id-*.md" -o -name "$id.md" \) 2>/dev/null | sort | head -1)"
      [ -n "$f" ] || continue
      t="$(sed -n 's/^\*\*Track:\*\*[[:space:]]*//p' "$f" | head -1)"
      [ "$t" = "$2" ] || continue
    fi
    printf '%s\n' "$id"
  done
}

_audited_ids() { # <target> -> numeric ids (as written in the ledger) already covered
  local led; led="$(evo_ledger "$1")"
  [ -f "$led" ] || return 0
  grep -oE 'retrospective audit of task #[0-9]+' "$led" 2>/dev/null \
    | grep -oE '[0-9]+$' | sort -u
}

case "$CMD" in
  init)
    dir="$(evo_dir "$TARGET")"; mkdir -p "$dir"
    if [ -f "$dir/personas.json" ]; then
      echo "evolve: roster already exists at $dir/personas.json (left untouched)"
    else
      cp "$PLUGIN_ROOT/templates/evolution/personas.json" "$dir/personas.json"
      echo "evolve: scaffolded default roster at $dir/personas.json — edit it for YOUR domain"
    fi
    _ensure_ledger "$TARGET"
    echo "evolve: ledger at $(evo_ledger "$TARGET")"
    echo "schema: templates/schemas/personas.schema.json (in the workbench plugin)"
    ;;

  validate)
    f="$(evo_roster "$TARGET")"
    [ -f "$f" ] || { echo "evolve: no roster at $f (run 'evolve.sh init' first)" >&2; exit 2; }
    if problems="$(_validate "$f")"; then
      echo "evolve: roster valid ($(_roster_tsv "$f" | wc -l | tr -d ' ') personas)"
    else
      echo "evolve: roster INVALID:" >&2
      printf '%s\n' "$problems" | sed 's/^/  - /' >&2
      exit 2
    fi
    ;;

  roster)
    f="$(evo_roster "$TARGET")"
    [ -f "$f" ] || { echo "evolve: no roster at $f (run 'evolve.sh init' first)" >&2; exit 2; }
    _roster_tsv "$f"
    ;;

  check)
    f="$(evo_roster "$TARGET")"
    if [ ! -f "$f" ]; then
      echo "disabled"
      echo "hint: evolution summits are opt-in — 'evolve.sh init' (or /workbench:evolve init) scaffolds the roster"
      exit 0
    fi
    if ! problems="$(_validate "$f")"; then
      echo "invalid"
      printf '%s\n' "$problems" | sed 's/^/  - /'
      exit 2
    fi
    low="$(_knob "$f" queue_low_water 2)"
    cad="$(_knob "$f" cadence_hours 24)"
    trk="${TRACK:-$(_knob "$f" track "")}"
    ready="$(_ready_ids "$TARGET" "$trk" | wc -l | tr -d ' ')"
    now="$(date +%s)"; stamp="$(evo_stamp "$TARGET")"
    last="never"; age_h="-"
    [ -f "$stamp" ] && last="$(tr -d ' \n' < "$stamp")"
    case "$last" in ''|*[!0-9]*) last="never" ;; esac
    reason=""
    if [ "$last" = "never" ]; then
      reason="no-summit-yet"
    else
      age_h=$(( (now - last) / 3600 ))
      if [ "$ready" -lt "$low" ]; then
        reason="backlog-low"
      elif [ $(( now - last )) -ge $(( cad * 3600 )) ]; then
        reason="summit-stale"
      fi
    fi
    if [ -n "$reason" ]; then echo "due $reason"; else echo "not-due"; fi
    echo "ready=$ready low_water=$low last_summit=$last age_hours=$age_h cadence_hours=$cad track=${trk:-any}"
    ;;

  record-summit)
    mkdir -p "$(evo_dir "$TARGET")"
    _ensure_ledger "$TARGET"
    date +%s > "$(evo_stamp "$TARGET")"
    printf '\n## Summit — %s\n' "$(date -u +'%Y-%m-%d %H:%M UTC')" >> "$(evo_ledger "$TARGET")"
    echo "evolve: summit recorded ($(date -u +'%Y-%m-%d %H:%M UTC'))"
    ;;

  log)
    [ -n "$PERSONA" ]     || { echo "evolve.sh: log requires --persona" >&2; exit 64; }
    [ -n "$IDEA" ]        || { echo "evolve.sh: log requires --idea" >&2; exit 64; }
    [ -n "$DISPOSITION" ] || { echo "evolve.sh: log requires --disposition" >&2; exit 64; }
    _ensure_ledger "$TARGET"
    printf -- '- [%s] %s — %s — %s\n' \
      "$(date -u +%Y-%m-%d)" "$(_clean "$PERSONA")" "$(_clean "$IDEA")" "$(_clean "$DISPOSITION")" \
      >> "$(evo_ledger "$TARGET")"
    echo "evolve: logged"
    ;;

  audited)
    _audited_ids "$TARGET"
    ;;

  retro-candidates)
    f="$(evo_roster "$TARGET")"
    limit="$LIMIT"
    if [ -z "$limit" ] && [ -f "$f" ]; then limit="$(_knob "$f" retro_slice 3)"; fi
    [ -n "$limit" ] || limit=3
    case "$limit" in ''|*[!0-9]*) echo "evolve.sh: --limit must be numeric" >&2; exit 64 ;; esac
    trk="$TRACK"
    if [ -z "$trk" ] && [ -f "$f" ]; then trk="$(_knob "$f" track "")"; fi
    T="$TARGET/.claude/tasks"
    audited=" $(_audited_ids "$TARGET" | awk '{ printf "%d ", $1 }')"
    for state in verified shipped; do
      for tf in "$T/$state"/*.md; do
        [ -e "$tf" ] || continue
        id="$(basename "$tf" .md | grep -oE '^[0-9]{3,}')"; [ -n "$id" ] || continue
        case "$audited" in *" $((10#$id)) "*) continue ;; esac
        if [ -n "$trk" ]; then
          t="$(sed -n 's/^\*\*Track:\*\*[[:space:]]*//p' "$tf" | head -1)"
          [ "$t" = "$trk" ] || continue
        fi
        printf '%s\n' "$id"
      done
    done | sort -n | head -n "$limit"
    ;;

  ''|help|--help|-h)
    sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'
    ;;

  *)
    echo "evolve.sh: unknown command '$CMD' (init|validate|roster|check|record-summit|log|audited|retro-candidates)" >&2
    exit 64
    ;;
esac
