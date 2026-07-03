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
#   evolve.sh init             [--target DIR] [--preset solo|crew|admin-example]
#                                scaffold roster + ledger (idempotent). Without --preset the
#                                tier follows the project's maturity level: solo -> the
#                                2-persona solo preset; pair/crew/fleet -> the 3+1 crew preset.
#                                admin-example is the worked 4-generator internal-admin panel.
#   evolve.sh validate         [--target DIR]              check the roster (exit 2 on invalid)
#   evolve.sh roster           [--target DIR]              TSV: name<TAB>role<TAB>prompt (exit 2 if invalid)
#   evolve.sh check            [--target DIR] [--track T]  first line: disabled | invalid | due <reason> | not-due
#   evolve.sh record-summit    [--target DIR] [--force]    stamp last-summit + ledger heading; the ATOMIC
#                                claim of a due summit — refuses (exit 75) if another session recorded
#                                one under EVOLVE_SUMMIT_GUARD_SECONDS (default 600) ago. --force overrides.
#   evolve.sh log --persona P --idea I --disposition D [--audit-of NNNN] [--target DIR]
#                                append a ledger entry. --audit-of writes the structural retrospective-
#                                audit marker for task NNNN (the ONLY thing rotation tracking counts —
#                                free text mentioning a task id is never treated as coverage).
#   evolve.sh audited          [--target DIR]              task ids already retrospectively audited
#   evolve.sh retro-candidates [--target DIR] [--track T] [--limit N]   oldest un-audited verified/shipped ids
#
# Concurrency: check/record-summit/log serialize under an advisory lock at
# .claude/locks/evolution.lock (il_lock in lib.sh — same discipline/location as the
# coord tooling's with-lock.sh). A held lock -> exit 75: skip and retry, don't crash.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # workbench/scripts
PLUGIN_ROOT="$(cd "$SELF_DIR/.." && pwd)"                  # workbench
. "$SELF_DIR/lib.sh"

evo_dir()    { printf '%s\n' "$(il_cfg_dir "$1")/evolution"; }
evo_roster() { printf '%s\n' "$(evo_dir "$1")/personas.json"; }
evo_ledger() { printf '%s\n' "$(evo_dir "$1")/ideas-log.md"; }
evo_stamp()  { printf '%s\n' "$(evo_dir "$1")/last-summit"; }

CMD="${1:-}"; [ "$#" -gt 0 ] && shift
TARGET="$PWD" TRACK="" LIMIT="" PERSONA="" IDEA="" DISPOSITION="" PRESET="" AUDIT_OF="" FORCE=0
need_arg() { [ "$#" -ge 2 ] || { echo "evolve.sh: $1 requires a value" >&2; exit 64; }; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --target)      need_arg "$@"; TARGET="$2"; shift 2 ;;
    --preset)      need_arg "$@"; PRESET="$2"; shift 2 ;;
    --track)       need_arg "$@"; TRACK="$2"; shift 2 ;;
    --limit)       need_arg "$@"; LIMIT="$2"; shift 2 ;;
    --persona)     need_arg "$@"; PERSONA="$2"; shift 2 ;;
    --idea)        need_arg "$@"; IDEA="$2"; shift 2 ;;
    --disposition) need_arg "$@"; DISPOSITION="$2"; shift 2 ;;
    --audit-of)    need_arg "$@"; AUDIT_OF="$2"; shift 2 ;;
    --force)       FORCE=1; shift ;;
    *) echo "evolve.sh: unknown arg '$1'" >&2; exit 64 ;;
  esac
done
TARGET="${TARGET%/}"; [ -n "$TARGET" ] || TARGET="/"

_die() { echo "evolve.sh: $*" >&2; exit 1; }

# one-line sanitize (ledger entries must stay one entry = one line). Removing
# TABS here is load-bearing: the retrospective-audit marker is a tab-delimited
# column only the `log --audit-of` code path can emit, so no persona/idea/
# disposition text (including AI-generated summit output) can forge it.
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
      if (depth == 1)                printf "knob\t%s\t%s\n", lastkey, v
      else if (depth >= 2 && pdepth) printf "p\t%d\t%s\t%s\n", pidx, lastkey, v
    }
    { buf = buf $0 "\n" }
    END {
      n = length(buf); depth = 0; instr = 0; esc = 0
      tok = ""; havetok = 0; lastkey = ""; expectval = 0
      pidx = 0; numtok = ""; innum = 0
      # pdepth = bracket depth at which the TOP-LEVEL "personas" array opened
      # (0 = not inside it). Only objects inside that array are personas —
      # a depth-2 object under any other key is ignored, never counted/emitted.
      adepth = 0; pdepth = 0
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
        else if (c == "{")  { depth++; if (depth == 2 && pdepth) pidx++; expectval = 0 }
        else if (c == "}")  { flush(); depth-- }
        else if (c == ",")  { flush() }
        else if (c == "[")  { flush(); adepth++; if (!pdepth && depth == 1 && lastkey == "personas") pdepth = adepth }
        else if (c == "]")  { flush(); if (pdepth && adepth == pdepth) pdepth = 0; adepth-- }
      }
      printf "meta\tpcount\t%d\n", pidx   # objects SEEN (even empty {}), for validation
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

# caps — mirrored in templates/schemas/personas.schema.json; enforced HERE because
# nothing else enforces the schema at runtime. They bound what a misconfigured or
# oversized roster can spawn/spend (personas = parallel agents, prompts = tokens,
# retro_slice = audited tasks per summit).
EVO_MAX_PERSONAS=10
EVO_MAX_PROMPT_CHARS=2000
EVO_MAX_RETRO_SLICE=20

_validate() { # <personas.json> -> problem lines on stdout; return 0 iff clean
  local tsv gens=0 crits=0 total=0 bad=0 line name role prompt rest dups pcount k v
  tsv="$(_roster_tsv "$1")"
  [ -n "$tsv" ] || { echo "no personas found (expected a 'personas' array of {name, role, prompt} objects)"; return 1; }
  # EVERY parsed object is validated — a nameless row is rejected outright, never
  # skipped (a skipped nameless critic used to bypass the exactly-one-critic check
  # while still reaching the roster downstream). Split fields manually: tab is IFS
  # whitespace, so `IFS=$'\t' read a b c` would silently swallow a LEADING empty
  # name field and shift role into name — exactly the row we must not misread.
  while IFS= read -r line; do
    total=$((total + 1))
    name="${line%%$'\t'*}"; rest="${line#*$'\t'}"
    role="${rest%%$'\t'*}"; prompt="${rest#*$'\t'}"
    # a name must contain at least one non-whitespace char — "  " is not a name
    case "$name" in
      *[![:space:]]*) : ;;
      *) echo "persona #$total has no name (every persona requires a non-blank name)"; bad=1; name="#$total" ;;
    esac
    [ -n "$prompt" ] || { echo "persona '$name' has an empty prompt"; bad=1; }
    [ "${#prompt}" -le "$EVO_MAX_PROMPT_CHARS" ] || { echo "persona '$name' prompt is ${#prompt} chars (max $EVO_MAX_PROMPT_CHARS)"; bad=1; }
    case "$role" in
      generator) gens=$((gens + 1)) ;;
      critic)    crits=$((crits + 1)) ;;
      *) echo "persona '$name' has invalid role '$role' (must be generator|critic)"; bad=1 ;;
    esac
  done <<< "$tsv"
  # objects with no fields at all ({}) emit no TSV row — catch them by comparing
  # the parser's SEEN-object count (meta row) against the validated row count
  pcount="$(evo_parse "$1" | awk -F'\t' '$1 == "meta" && $2 == "pcount" { print $3; exit }')"
  pcount="${pcount:-$total}"
  [ "$pcount" -eq "$total" ] || { echo "personas array contains $(( pcount - total )) empty object(s) (every persona requires name, role, prompt)"; bad=1; }
  [ "$total" -le "$EVO_MAX_PERSONAS" ] || { echo "too many personas ($total > $EVO_MAX_PERSONAS) — each persona is a parallel agent; a panel this large dilutes every voice and inflates cost"; bad=1; }
  dups="$(printf '%s\n' "$tsv" | cut -f1 | awk 'NF' | sort | uniq -d)"
  [ -z "$dups" ] || { echo "duplicate persona name(s): $(printf '%s' "$dups" | tr '\n' ' ')"; bad=1; }
  [ "$gens" -ge 1 ]  || { echo "roster needs at least one generator persona (found $gens)"; bad=1; }
  [ "$crits" -eq 1 ] || { echo "roster needs exactly ONE critic persona (found $crits)"; bad=1; }
  # knobs: check's bash arithmetic needs integers — fail HERE at validate time,
  # not with a cryptic arithmetic error at check time
  while IFS=$'\t' read -r _ k v; do
    case "$k" in
      cadence_hours)
        case "$v" in ''|*[!0-9]*) echo "knob cadence_hours must be a positive integer (got '$v')"; bad=1 ;;
          *) [ "$v" -ge 1 ] || { echo "knob cadence_hours must be >= 1 (got $v)"; bad=1; } ;; esac ;;
      queue_low_water)
        case "$v" in ''|*[!0-9]*) echo "knob queue_low_water must be a non-negative integer (got '$v')"; bad=1 ;; esac ;;
      retro_slice)
        case "$v" in ''|*[!0-9]*) echo "knob retro_slice must be a non-negative integer (got '$v')"; bad=1 ;;
          *) [ "$v" -le "$EVO_MAX_RETRO_SLICE" ] || { echo "knob retro_slice must be <= $EVO_MAX_RETRO_SLICE (got $v)"; bad=1; } ;; esac ;;
    esac
  done < <(evo_parse "$1" | awk -F'\t' '$1 == "knob"')
  return "$bad"
}

_ensure_ledger() { # <target>; returns non-zero if the ledger cannot be created
  local led; led="$(evo_ledger "$1")"
  [ -f "$led" ] && return 0
  mkdir -p "$(evo_dir "$1")" || return 1
  il_render "$PLUGIN_ROOT/templates/evolution/ideas-log.md.tmpl" "$led" \
    "CREATED=$(date -u +%Y-%m-%d)" || return 1
  [ -f "$led" ]
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

# Retrospective coverage is tracked by a STRUCTURAL marker, not free text: an
# audit entry is "- [YYYY-MM-DD]<TAB>[audit:#NNNN]<TAB>...", and only the
# `log --audit-of` code path can produce that shape (persona/idea/disposition
# text is tab-stripped by _clean, and record-summit/log are the only writers).
# A free-text "retrospective audit of task #7" inside an idea — including
# adversarial AI-generated summit output — can therefore never mark a task
# as covered.
_audited_ids() { # <target> -> ids (as written in the ledger) already covered
  local led; led="$(evo_ledger "$1")"
  [ -f "$led" ] || return 0
  awk -F'\t' '
    $1 ~ /^- \[[0-9]{4}-[0-9]{2}-[0-9]{2}\]$/ && $2 ~ /^\[audit:#[0-9]+\]$/ {
      id = $2; sub(/^\[audit:#/, "", id); sub(/\]$/, "", id); print id
    }
  ' "$led" 2>/dev/null | sort -u
}

case "$CMD" in
  init)
    dir="$(evo_dir "$TARGET")"
    mkdir -p "$dir" || _die "cannot create $dir"
    if [ -f "$dir/personas.json" ]; then
      echo "evolve: roster already exists at $dir/personas.json (left untouched)"
    else
      # Preset tiers follow the existing maturity ladder — no separate preset dial.
      if [ -z "$PRESET" ]; then
        lvl="$(sed -n 's/.*"level"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$(il_cfg_dir "$TARGET")/config.json" 2>/dev/null | head -1)"
        case "$lvl" in
          solo) PRESET="solo" ;;
          *)    PRESET="crew" ;;   # pair/crew/fleet: split generators by real domains
        esac
        echo "evolve: level '${lvl:-unknown}' -> preset '$PRESET' (override with --preset solo|crew|admin-example)"
      fi
      src="$PLUGIN_ROOT/templates/evolution/personas.$PRESET.json"
      [ -f "$src" ] || { echo "evolve.sh: unknown preset '$PRESET' (solo|crew|admin-example)" >&2; exit 64; }
      cp "$src" "$dir/personas.json" || _die "cannot write $dir/personas.json"
      echo "evolve: scaffolded '$PRESET' roster at $dir/personas.json — rewrite the generators for YOUR domain"
    fi
    _ensure_ledger "$TARGET" || _die "cannot create ledger at $(evo_ledger "$TARGET")"
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
    # never emit a panel from an invalid roster — an unvalidated roster could
    # smuggle e.g. a second (nameless) critic past the exactly-one-critic rule
    if ! problems="$(_validate "$f")"; then
      echo "evolve: roster INVALID — refusing to emit a panel:" >&2
      printf '%s\n' "$problems" | sed 's/^/  - /' >&2
      exit 2
    fi
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
    # serialize with record-summit so a stamp mid-write can't be misread
    il_lock "$TARGET" evolution || exit 75
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
      elif [ $(( now - last )) -gt $(( cad * 3600 )) ]; then
        # strictly MORE than cadence_hours, per the spec — not at-exactly
        reason="summit-stale"
      fi
    fi
    if [ -n "$reason" ]; then echo "due $reason"; else echo "not-due"; fi
    echo "ready=$ready low_water=$low last_summit=$last age_hours=$age_h cadence_hours=$cad track=${trk:-any}"
    ;;

  record-summit)
    # THE atomic claim of a due summit. Two leads can both observe `check` = due;
    # only the first record-summit wins — the second is refused by the duplicate
    # guard below (exit 75) and must skip its summit.
    il_lock "$TARGET" evolution || exit 75
    stamp="$(evo_stamp "$TARGET")"
    if [ "$FORCE" != 1 ] && [ -f "$stamp" ]; then
      last="$(tr -d ' \n' < "$stamp")"
      case "$last" in ''|*[!0-9]*) last=0 ;; esac
      gap="${EVOLVE_SUMMIT_GUARD_SECONDS:-600}"
      age=$(( $(date +%s) - last ))
      # negative age = future-dated stamp (clock skew / bad write): treat it as
      # freshly recorded and still refuse — never silently disable the guard
      if [ "$age" -lt "$gap" ]; then
        echo "evolve: a summit was recorded ${age}s ago (< ${gap}s guard) — refusing a duplicate; another session likely claimed this summit (--force to override)" >&2
        exit 75
      fi
    fi
    mkdir -p "$(evo_dir "$TARGET")" || _die "cannot create $(evo_dir "$TARGET")"
    _ensure_ledger "$TARGET" || _die "cannot create ledger at $(evo_ledger "$TARGET")"
    date +%s > "$stamp" || _die "cannot write summit stamp $stamp"
    printf '\n## Summit — %s\n' "$(date -u +'%Y-%m-%d %H:%M UTC')" >> "$(evo_ledger "$TARGET")" \
      || _die "cannot append to ledger $(evo_ledger "$TARGET")"
    echo "evolve: summit recorded ($(date -u +'%Y-%m-%d %H:%M UTC'))"
    ;;

  log)
    [ -n "$PERSONA" ]     || { echo "evolve.sh: log requires --persona" >&2; exit 64; }
    [ -n "$IDEA" ]        || { echo "evolve.sh: log requires --idea" >&2; exit 64; }
    [ -n "$DISPOSITION" ] || { echo "evolve.sh: log requires --disposition" >&2; exit 64; }
    if [ -n "$AUDIT_OF" ]; then
      case "$AUDIT_OF" in ''|*[!0-9]*) echo "evolve.sh: --audit-of must be a numeric task id (got '$AUDIT_OF')" >&2; exit 64 ;; esac
    fi
    il_lock "$TARGET" evolution || exit 75
    _ensure_ledger "$TARGET" || _die "cannot create ledger at $(evo_ledger "$TARGET")"
    if [ -n "$AUDIT_OF" ]; then
      # tab-delimited marker column — see _audited_ids for why this shape is
      # the only thing retrospective-coverage tracking will count
      printf -- '- [%s]\t[audit:#%s]\t%s — %s — %s\n' \
        "$(date -u +%Y-%m-%d)" "$AUDIT_OF" "$(_clean "$PERSONA")" "$(_clean "$IDEA")" "$(_clean "$DISPOSITION")" \
        >> "$(evo_ledger "$TARGET")" || _die "cannot append to ledger $(evo_ledger "$TARGET")"
    else
      printf -- '- [%s] %s — %s — %s\n' \
        "$(date -u +%Y-%m-%d)" "$(_clean "$PERSONA")" "$(_clean "$IDEA")" "$(_clean "$DISPOSITION")" \
        >> "$(evo_ledger "$TARGET")" || _die "cannot append to ledger $(evo_ledger "$TARGET")"
    fi
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
    [ "$limit" -le "$EVO_MAX_RETRO_SLICE" ] || { echo "evolve.sh: --limit must be <= $EVO_MAX_RETRO_SLICE (got $limit)" >&2; exit 64; }
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
    sed -n '2,38p' "$0" | sed 's/^# \{0,1\}//'
    ;;

  *)
    echo "evolve.sh: unknown command '$CMD' (init|validate|roster|check|record-summit|log|audited|retro-candidates)" >&2
    exit 64
    ;;
esac
