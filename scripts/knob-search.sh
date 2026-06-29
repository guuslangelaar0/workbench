#!/usr/bin/env bash
# BM-6 — KNOB SEARCH. The conformance benchmark, turned into an optimizer.
#
# A "knob" is anything that shapes how the model reads the plugin: a command/skill
# description, the scaffolded CLAUDE.md routing table, a dial/level preset. A CANDIDATE is
# an OVERLAY — a tree of files copied over a fresh plugin checkout. The search scores the
# current plugin (the "baseline") and every candidate against the conformance TRAIN set,
# ranks them, and PROPOSES the winner.
#
# Recommend-only by design: it PRINTS the command to apply the winning overlay; it NEVER
# mutates the plugin. A strict winner is then validated on the HELD-OUT set — a candidate
# that wins on train but not on holdout is flagged as overfit and NOT recommended (the
# Goodhart guard, design §5.4). Ties keep the baseline: we don't churn descriptions for noise.
#
# Candidates live in <candidates>/<name>/ (default test/benchmark/knobs/candidates/):
#   overlay/…   files to copy over the plugin root (the knob change)
#   note        (optional) one-line description of what this candidate changes
#
# Scoring drives the real conformance benchmark (bench-intents.sh) against a temp copy of
# the plugin with the overlay applied. Live scoring costs API tokens and is gated by
# WB_BENCH=1, exactly like bench-intents; --simulate runs the harness offline (free) — but
# simulate fakes the correct behavior regardless of descriptions, so it CANNOT tell
# candidates apart (use it only to prove the plumbing). Offline RANKING-logic tests set
# WB_KNOB_STUB=1, which reads each candidate's score from a stub file instead of running.
#
# Usage: knob-search.sh [--simulate] [--candidates DIR] [--keep]
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SELF_DIR/.." && pwd)"
CAND_DIR="$ROOT/test/benchmark/knobs/candidates"
SIMULATE=0 KEEP=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --simulate)   SIMULATE=1; shift ;;
    --candidates) CAND_DIR="$2"; shift 2 ;;
    --keep)       KEEP=1; shift ;;
    *) echo "knob-search.sh: unknown arg '$1'" >&2; exit 64 ;;
  esac
done
# stub scoring (offline ranking-logic tests): scores read from <STUB_DIR>/<name>.<set>
STUB_DIR="${WB_KNOB_STUB_DIR:-$CAND_DIR}"

if [ "$SIMULATE" = 0 ] && [ "${WB_KNOB_STUB:-0}" != 1 ] && [ "${WB_BENCH:-0}" != 1 ]; then
  echo "knob-search.sh: scoring candidates drives the real conformance benchmark and COSTS" >&2
  echo "  API TOKENS. Set WB_BENCH=1 to run it live, or --simulate for the free plumbing check." >&2
  exit 2
fi

pct() { awk -F/ 'BEGIN{p=0}{ if ($2>0) p=100*$1/$2 } END{ printf "%.2f", p }' <<EOF
$1
EOF
}

# echo "P/T" for a candidate (name, overlay-dir or "", set)
score_overlay() {
  local name="$1" odir="$2" set="$3"
  if [ "${WB_KNOB_STUB:-0}" = 1 ]; then
    local s; s="$(tr -d ' \n' < "$STUB_DIR/$name.$set" 2>/dev/null)"
    printf '%s' "${s:-0/0}"; return
  fi
  local tmp; tmp="$(mktemp -d)"
  cp -r "$ROOT"/. "$tmp"/ 2>/dev/null; rm -rf "$tmp/.git"
  [ -n "$odir" ] && [ -d "$odir" ] && cp -r "$odir"/. "$tmp"/ 2>/dev/null
  local flags="--set $set"; [ "$SIMULATE" = 1 ] && flags="--simulate $flags"
  local out; out="$( WB_BENCH="${WB_BENCH:-0}" bash "$tmp/scripts/bench-intents.sh" $flags 2>/dev/null )"
  [ "$KEEP" = 1 ] || rm -rf "$tmp"
  local raw; raw="$(printf '%s' "$out" | sed -n 's/.*conformance=\([0-9]*\/[0-9]*\).*/\1/p' | head -1)"
  printf '%s' "${raw:-0/0}"
}

[ -d "$CAND_DIR" ] || { echo "knob-search.sh: no candidates dir at $CAND_DIR (nothing to search)"; exit 0; }
cands=()
for d in "$CAND_DIR"/*/; do [ -d "$d" ] && cands+=("$d"); done

echo "KNOB SEARCH — conformance(train), recommend-only"
echo "─────────────────────────────────────────────"

base_raw="$(score_overlay baseline "" train)"; base_pct="$(pct "$base_raw")"
printf '  %-26s %s  (%s%%)   [current]\n' "baseline" "$base_raw" "$base_pct"

best_name="baseline" best_pct="$base_pct" best_overlay=""
# print every candidate, track the strict winner (ties keep baseline)
for d in "${cands[@]:-}"; do
  [ -n "$d" ] || continue
  name="$(basename "$d")"
  raw="$(score_overlay "$name" "$d/overlay" train)"; p="$(pct "$raw")"
  note="$(head -1 "$d/note" 2>/dev/null)"
  printf '  %-26s %s  (%s%%)   %s\n' "$name" "$raw" "$p" "$note"
  awk -v a="$p" -v b="$best_pct" 'BEGIN{ exit !(a>b) }' && { best_name="$name"; best_pct="$p"; best_overlay="$d/overlay"; }
done

echo "─────────────────────────────────────────────"
if [ "$best_name" = "baseline" ]; then
  echo "WINNER: baseline — no candidate strictly beats the current plugin on train. Keep it."
  exit 0
fi

# strict winner found → validate on the held-out set before recommending (anti-overfit)
win_h="$(score_overlay "$best_name" "$best_overlay" holdout)"; win_hp="$(pct "$win_h")"
base_h="$(score_overlay baseline "" holdout)"; base_hp="$(pct "$base_h")"
echo "TRAIN winner: $best_name ($best_pct%) > baseline ($base_pct%)"
echo "HOLDOUT check: $best_name=$win_h ($win_hp%)  baseline=$base_h ($base_hp%)"
if awk -v a="$win_hp" -v b="$base_hp" 'BEGIN{ exit !(a>=b) }'; then
  echo "RECOMMEND: apply '$best_name' — it wins on train AND holds on holdout (recommend-only)."
  echo "  to apply:  cp -r '$CAND_DIR/$best_name/overlay/.' '$ROOT/'   # then re-run the full test suite"
else
  echo "REJECT: '$best_name' wins on train but DROPS on holdout — overfit to the train set. Do NOT apply."
fi
exit 0
