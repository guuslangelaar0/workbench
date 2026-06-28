#!/usr/bin/env bash
# workbench COST / BUDGET GOVERNANCE. Spend is tracked in EXACT TOKENS (from the session
# transcript, snapshotted by the usage-meter hook) — no fabricated USD prices, so nothing
# bitrots. A USD estimate is shown ONLY if you set per-MTok prices. A token ceiling lets
# the loop govern itself: as projected spend approaches it, downshift; at it, pause + suggest.
#
# Storage:
#   <cfg>/usage/current.tsv   latest cumulative (written by usage-meter hook)
#   <cfg>/ledger.tsv          per-task spend rows (id, start_total, close_total, delta, ts)
#   config.json budget{}      ceiling_tokens, on_approach, approach_pct, price_in, price_out
#
# Usage:
#   budget.sh show [--target DIR]
#   budget.sh check [--target DIR]                 exit 0 ok/approaching · 3 over ceiling
#   budget.sh set --ceiling-tokens N | --on-approach downshift|pause|notify
#               | --approach-pct P | --price-in USD_PER_MTOK | --price-out USD_PER_MTOK
#   budget.sh task <id> start|close [--target DIR] record a per-task spend delta into the ledger
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SELF_DIR/lib.sh"

CMD="${1:-}"; [ "$#" -gt 0 ] && shift
TARGET="$PWD" CEIL="" ONAPP="" PCT="" PIN="" POUT=""
POS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --target)        TARGET="$2"; shift 2 ;;
    --ceiling-tokens) CEIL="$2"; shift 2 ;;
    --on-approach)   ONAPP="$2"; shift 2 ;;
    --approach-pct)  PCT="$2"; shift 2 ;;
    --price-in)      PIN="$2"; shift 2 ;;
    --price-out)     POUT="$2"; shift 2 ;;
    -*) echo "budget.sh: unknown flag '$1'" >&2; exit 64 ;;
    *)  POS+=("$1"); shift ;;
  esac
done
TARGET="${TARGET%/}"; [ -n "$TARGET" ] || TARGET="/"
CFG="$(il_cfg_dir "$TARGET")/config.json"
SNAP="$(il_cfg_dir "$TARGET")/usage/current.tsv"
LEDGER="$(il_cfg_dir "$TARGET")/ledger.tsv"

cfg_int()   { sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\([0-9.][0-9.]*\).*/\1/p" "$CFG" 2>/dev/null | head -1; }
cfg_str()   { sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$CFG" 2>/dev/null | head -1; }

# read snapshot fields (cumulative). billable = input + output + cache_write (cache_read is ~free-ish)
snap_field() { [ -f "$SNAP" ] && cut -f"$1" "$SNAP" 2>/dev/null | head -1 || echo ""; }
read_usage() {
  S_IN="$(snap_field 3)"; S_OUT="$(snap_field 4)"; S_CR="$(snap_field 5)"; S_CW="$(snap_field 6)"
  S_TURNS="$(snap_field 7)"; S_SRC="$(snap_field 8)"
  : "${S_IN:=0}" "${S_OUT:=0}" "${S_CR:=0}" "${S_CW:=0}" "${S_TURNS:=0}" "${S_SRC:=none}"
  TOTAL=$(( S_IN + S_OUT + S_CW ))   # billable tokens (excludes cache reads)
}

usd_estimate() { # echoes a "~$X.XX" string if prices are set, else nothing
  local pin pout; pin="$(cfg_int price_in)"; pout="$(cfg_int price_out)"
  [ -n "$pin" ] || [ -n "$pout" ] || return 0
  : "${pin:=0}" "${pout:=0}"
  awk -v i="$S_IN" -v o="$S_OUT" -v cw="$S_CW" -v pi="$pin" -v po="$pout" \
    'BEGIN{ printf "~$%.2f", ((i+cw)/1000000.0)*pi + (o/1000000.0)*po }'
}

fmt() { # humanize a token count: 1234567 -> 1.23M
  awk -v n="$1" 'BEGIN{ if(n>=1e6) printf "%.2fM", n/1e6; else if(n>=1e3) printf "%.1fk", n/1e3; else printf "%d", n }'
}

case "$CMD" in
  show)
    read_usage
    ceil="$(cfg_int ceiling_tokens)"
    echo "Spend (session, exact-source=$S_SRC):"
    printf '  input %s · output %s · cache-write %s · cache-read %s · turns %s\n' \
      "$(fmt "$S_IN")" "$(fmt "$S_OUT")" "$(fmt "$S_CW")" "$(fmt "$S_CR")" "$S_TURNS"
    printf '  billable total: %s tokens' "$(fmt "$TOTAL")"
    u="$(usd_estimate)"; [ -n "$u" ] && printf '  (%s est)' "$u"
    echo ""
    if [ -n "$ceil" ] && [ "$ceil" -gt 0 ] 2>/dev/null; then
      pctnum="$(awk -v t="$TOTAL" -v c="$ceil" 'BEGIN{printf "%d", (t*100)/c}')"
      onapp="$(cfg_str on_approach)"; [ -n "$onapp" ] || onapp=downshift
      printf '  ceiling: %s tokens · %s%% used · on-approach=%s\n' "$(fmt "$ceil")" "$pctnum" "$onapp"
    else
      echo "  ceiling: (none set — budget.sh set --ceiling-tokens N)"
    fi
    [ "$S_SRC" = none ] && echo "  note: no usage snapshot yet — enable the usage-meter hook (ships with the plugin) and let one turn end."
    [ "$S_SRC" = estimate ] && echo "  note: counts are an awk estimate (no python3/jq) — may overcount; install python3 for exact."
    ;;

  check)
    read_usage
    ceil="$(cfg_int ceiling_tokens)"
    [ -n "$ceil" ] && [ "$ceil" -gt 0 ] 2>/dev/null || { echo "budget: no ceiling set (ok)"; exit 0; }
    pct="$(cfg_int approach_pct)"; [ -n "$pct" ] || pct=80
    onapp="$(cfg_str on_approach)"; [ -n "$onapp" ] || onapp=downshift
    pctnum="$(awk -v t="$TOTAL" -v c="$ceil" 'BEGIN{printf "%d", (t*100)/c}')"
    if [ "$TOTAL" -ge "$ceil" ]; then
      [ -x "$SELF_DIR/suggest.sh" ] && bash "$SELF_DIR/suggest.sh" add --key budget-over --severity warn \
        --title "Budget ceiling reached ($(fmt "$TOTAL")/$(fmt "$ceil") tokens)" \
        --why "session billable tokens hit the ceiling; on_approach=$onapp" \
        --how "pause non-essential work, or raise it: /workbench:budget set --ceiling-tokens <N>" \
        --source budget --target "$TARGET" >/dev/null 2>&1 || true
      echo "budget: OVER ceiling ($pctnum%) — on_approach=$onapp" >&2
      exit 3
    elif [ "$pctnum" -ge "$pct" ]; then
      [ -x "$SELF_DIR/suggest.sh" ] && bash "$SELF_DIR/suggest.sh" add --key budget-approach --severity recommend \
        --title "Approaching budget ceiling (${pctnum}% of $(fmt "$ceil") tokens)" \
        --why "session spend is at ${pctnum}% of the ceiling" \
        --how "downshift models/parallelism now, or raise the ceiling: /workbench:budget set --ceiling-tokens <N>" \
        --source budget --target "$TARGET" >/dev/null 2>&1 || true
      echo "budget: approaching ceiling ($pctnum%)"
      exit 0
    fi
    echo "budget: ok ($pctnum% of ceiling)"
    ;;

  set)
    [ -f "$CFG" ] || { echo "budget.sh: no config at $CFG (run /workbench setup)" >&2; exit 1; }
    # upsert keys into a budget{} object using python3 if present, else a safe sed/append.
    if command -v python3 >/dev/null 2>&1; then
      python3 - "$CFG" "$CEIL" "$ONAPP" "$PCT" "$PIN" "$POUT" <<'PY' || { echo "budget.sh: failed to write config" >&2; exit 1; }
import json,sys
f=sys.argv[1]; ceil,onapp,pct,pin,pout=sys.argv[2:7]
c=json.load(open(f)); b=c.get("budget") or {}
if ceil:  b["ceiling_tokens"]=int(ceil)
if onapp: b["on_approach"]=onapp
if pct:   b["approach_pct"]=int(pct)
if pin:   b["price_in"]=float(pin)
if pout:  b["price_out"]=float(pout)
c["budget"]=b
json.dump(c,open(f,"w"),indent=2); print("ok")
PY
      echo "budget: updated $CFG"
    else
      echo "budget.sh: python3 not available — set the 'budget' object in $CFG by hand:" >&2
      echo '  "budget": { "ceiling_tokens": N, "on_approach": "downshift", "approach_pct": 80 }' >&2
      exit 1
    fi
    ;;

  task)
    id="${POS[0]:-}"; phase="${POS[1]:-}"
    [ -n "$id" ] && [ -n "$phase" ] || { echo "budget.sh: task requires <id> start|close" >&2; exit 64; }
    read_usage
    case "$phase" in
      start)
        printf '%s\tstart\t%s\t%s\n' "$id" "$TOTAL" "$(date +%s)" >> "$LEDGER"
        echo "budget: task $id start @ $(fmt "$TOTAL") tokens"
        ;;
      close)
        start_total="$(awk -F'\t' -v id="$id" '$1==id && $2=="start"{v=$3} END{print v+0}' "$LEDGER" 2>/dev/null)"
        delta=$(( TOTAL - ${start_total:-0} )); [ "$delta" -lt 0 ] && delta=0
        printf '%s\tclose\t%s\t%s\tdelta=%s\n' "$id" "$TOTAL" "$(date +%s)" "$delta" >> "$LEDGER"
        echo "budget: task $id close @ $(fmt "$TOTAL") tokens · this task ≈ $(fmt "$delta") tokens"
        ;;
      *) echo "budget.sh: phase must be start|close" >&2; exit 64 ;;
    esac
    ;;

  ""|-h|--help|help)
    sed -n '2,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
    [ -n "$CMD" ] && exit 0 || exit 64
    ;;
  *)
    echo "budget.sh: unknown subcommand '$CMD' (show|check|set|task)" >&2; exit 64 ;;
esac
exit 0
