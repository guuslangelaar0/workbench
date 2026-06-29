#!/usr/bin/env bash
# workbench EXPECTANCY SCORECARD. Treats each task as a "trade" and computes the loop's
# expected net verified-value per task and per 100k tokens, from the durable metrics log
# (metrics.tsv) + the token ledger (ledger.tsv). One number to watch as you tune the way
# of working. Zero API cost — pure aggregation of what actually happened.
#
# A clean close is a WIN; a bounce/gaming-flag/regression is a LOSS that subtracts value,
# so a *gamed* close lowers expectancy rather than inflating it (scores reality, not claims).
#
# Weights (config `score`{} object; defaults below):
#   win=100  bounce=40  game=150  regress=80  restart=10  drift=15
# Usage: score.sh [--target DIR] [--quiet]   (--quiet prints only the per-task expectancy)
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SELF_DIR/lib.sh"

TARGET="$PWD" QUIET=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --target) TARGET="$2"; shift 2 ;;
    --quiet)  QUIET=1; shift ;;
    -*) echo "score.sh: unknown flag '$1'" >&2; exit 64 ;;
    *)  shift ;;
  esac
done
TARGET="${TARGET%/}"; [ -n "$TARGET" ] || TARGET="/"
CFG="$(il_cfg_dir "$TARGET")/config.json"
LOG="$(il_cfg_dir "$TARGET")/metrics.tsv"
LEDGER="$(il_cfg_dir "$TARGET")/ledger.tsv"
SDIR="$(il_cfg_dir "$TARGET")/score"; LAST="$SDIR/last"

w() { local v; v="$(sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p" "$CFG" 2>/dev/null | head -1)"; [ -n "$v" ] && echo "$v" || echo "$2"; }
W_WIN="$(w win 100)"; W_BOUNCE="$(w bounce 40)"; W_GAME="$(w game 150)"; W_REGRESS="$(w regress 80)"; W_RESTART="$(w restart 10)"; W_DRIFT="$(w drift 15)"

count() { [ -f "$LOG" ] && awk -F'\t' -v e="$1" '$2==e{n++} END{print n+0}' "$LOG" || echo 0; }
closed="$(count task_closed)"; bounced="$(count task_bounced)"; gamed="$(count gaming_flag)"
regressed="$(count regression_red)"; restarts="$(count restart)"; drift="$(count drift_due)"

# tokens attributed to tasks (sum of ledger close deltas); fall back to cumulative billable
tokens=0
if [ -f "$LEDGER" ]; then
  tokens="$(awk -F'\t' '$2=="close"{for(i=1;i<=NF;i++) if($i ~ /^delta=/){sub(/delta=/,"",$i); s+=$i}} END{print s+0}' "$LEDGER")"
fi
SNAP="$(il_cfg_dir "$TARGET")/usage/current.tsv"
if [ "${tokens:-0}" -le 0 ] && [ -f "$SNAP" ]; then
  tokens="$(awk -F'\t' 'NR==1{print ($3+$4+$6)}' "$SNAP" 2>/dev/null)"; tokens="${tokens:-0}"
fi

read -r net per_task per_100k grade winrate <<EOF
$(awk -v c="$closed" -v b="$bounced" -v g="$gamed" -v r="$regressed" -v x="$restarts" -v d="$drift" \
      -v tok="$tokens" -v WW="$W_WIN" -v WB="$W_BOUNCE" -v WG="$W_GAME" -v WR="$W_REGRESS" -v WX="$W_RESTART" -v WD="$W_DRIFT" '
  BEGIN{
    net = c*WW - b*WB - g*WG - r*WR - x*WX - d*WD
    attempts = c + b
    pt   = (attempts>0) ? net/attempts : 0
    p100 = (tok>0) ? net/(tok/100000.0) : 0
    gross = c*WW
    grade = (gross>0) ? 100.0*net/gross : 0
    if (grade<0) grade=0; if (grade>100) grade=100
    wr = (attempts>0) ? 100.0*c/attempts : 0
    printf "%d %.1f %.1f %.0f %.0f", net, pt, p100, grade, wr
  }')
EOF

if [ "$QUIET" = 1 ]; then echo "$per_task"; exit 0; fi

# trend vs last score
prev_pt=""; [ -f "$LAST" ] && prev_pt="$(cut -f2 "$LAST" 2>/dev/null)"
trend=""
if [ -n "$prev_pt" ]; then
  trend="$(awk -v a="$per_task" -v b="$prev_pt" 'BEGIN{d=a-b; printf "%s%.1f vs last", (d>=0?"+":""), d}')"
fi

band() { awk -v g="$1" 'BEGIN{ if(g>=85)print"A (excellent)"; else if(g>=70)print"B (healthy)"; else if(g>=50)print"C (mixed)"; else if(g>=30)print"D (leaky)"; else print"F (the loop is fighting itself)" }'; }

echo "workbench expectancy — $(basename "$TARGET")"
echo "─────────────────────────────────────────────"
if [ "$((closed + bounced))" -eq 0 ]; then
  echo "No resolved tasks yet — expectancy needs closes/bounces in the metrics log."
  echo "(it fills as tasks move through verify and the gates run.)"
  exit 0
fi
printf "  wins (clean closes)   %d\n" "$closed"
printf "  losses                bounced %d · gamed %d · regressed %d\n" "$bounced" "$gamed" "$regressed"
printf "  friction              restarts %d · drift episodes %d\n" "$restarts" "$drift"
printf "  win rate              %s%%\n" "$winrate"
printf "  tokens (attributed)   %s\n" "$(awk -v n="$tokens" 'BEGIN{if(n>=1e6)printf"%.2fM",n/1e6; else if(n>=1e3)printf"%.1fk",n/1e3; else printf"%d",n}')"
echo "─────────────────────────────────────────────"
printf "  EXPECTANCY / task     %s   %s\n" "$per_task" "$trend"
[ "${tokens:-0}" -gt 0 ] && printf "  EXPECTANCY / 100k tok %s\n" "$per_100k"
printf "  GRADE                 %s/100  — %s\n" "$grade" "$(band "$grade")"
echo "─────────────────────────────────────────────"
echo "  weights: win=$W_WIN bounce=$W_BOUNCE game=$W_GAME regress=$W_REGRESS restart=$W_RESTART drift=$W_DRIFT (config 'score'{})"

# persist for trend + machine parse
mkdir -p "$SDIR" 2>/dev/null || true
printf '%s\t%s\t%s\t%s\t%s\n' "$net" "$per_task" "$per_100k" "$grade" "$(date +%s)" > "$LAST" 2>/dev/null || true
echo "EXPECTANCY/task=$per_task EXPECTANCY/100k=$per_100k grade=$grade"
exit 0
