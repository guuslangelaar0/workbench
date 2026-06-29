#!/usr/bin/env bash
# BM-6 — knob search. The RANKING logic is verified offline with stubbed per-candidate
# scores (WB_KNOB_STUB=1): a tie must keep the baseline, a strict train winner that also
# holds on holdout must be RECOMMENDED, and a train winner that drops on holdout must be
# REJECTED as overfit. A separate --simulate smoke proves the real copy+overlay+run
# plumbing works against the shipped example candidate. The live path is gated by WB_BENCH=1.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KS="$ROOT/scripts/knob-search.sh"
fail=0
chk() { if eval "$2"; then echo "ok: $1"; else echo "FAIL: $1" >&2; fail=1; fi; }

# build a stub candidates dir: empty candidate subdirs + <name>.<set> score files.
mkstub() { # $1=dir ; reads remaining args as "name=train/holdout" (baseline included)
  local d="$1"; shift; mkdir -p "$d"
  local spec n sc trn hld
  for spec in "$@"; do
    n="${spec%%=*}"; sc="${spec#*=}"; trn="${sc%%:*}"; hld="${sc#*:}"
    [ "$n" != baseline ] && mkdir -p "$d/$n"
    printf '%s' "$trn" > "$d/$n.train"; printf '%s' "$hld" > "$d/$n.holdout"
  done
}

# scenario 1 — a candidate TIES the baseline on train -> keep baseline (no churn on noise)
T1="$(mktemp -d)"; mkstub "$T1" "baseline=8/8:3/3" "tie-cand=8/8:3/3"
O1="$(WB_KNOB_STUB=1 WB_KNOB_STUB_DIR="$T1" bash "$KS" --candidates "$T1" 2>&1)"
chk "tie keeps baseline"         "printf '%s' \"\$O1\" | grep -q 'WINNER: baseline'"
chk "tie does not recommend"     "! printf '%s' \"\$O1\" | grep -q 'RECOMMEND: apply'"

# scenario 2 — a candidate STRICTLY wins on train AND holds on holdout -> recommend it
T2="$(mktemp -d)"; mkstub "$T2" "baseline=6/8:2/3" "better=8/8:3/3"
O2="$(WB_KNOB_STUB=1 WB_KNOB_STUB_DIR="$T2" bash "$KS" --candidates "$T2" 2>&1)"
chk "strict winner detected"     "printf '%s' \"\$O2\" | grep -q 'TRAIN winner: better'"
chk "holdout check runs"         "printf '%s' \"\$O2\" | grep -q 'HOLDOUT check:'"
chk "winner is recommended"      "printf '%s' \"\$O2\" | grep -q 'RECOMMEND: apply .better.'"
chk "prints a recommend-only apply command" "printf '%s' \"\$O2\" | grep -q 'cp -r'"

# scenario 3 — wins on train but DROPS on holdout -> rejected as overfit (Goodhart guard)
T3="$(mktemp -d)"; mkstub "$T3" "baseline=6/8:3/3" "overfit=8/8:1/3"
O3="$(WB_KNOB_STUB=1 WB_KNOB_STUB_DIR="$T3" bash "$KS" --candidates "$T3" 2>&1)"
chk "overfit winner detected on train" "printf '%s' \"\$O3\" | grep -q 'TRAIN winner: overfit'"
chk "overfit is REJECTED"        "printf '%s' \"\$O3\" | grep -q 'REJECT'"
chk "overfit is NOT recommended" "! printf '%s' \"\$O3\" | grep -q 'RECOMMEND: apply'"

# live path refuses without a cost gate
chk "refuses without gate (exit 2)" "bash '$KS' >/dev/null 2>&1; [ \$? -eq 2 ]"
chk "rejects unknown arg (exit 64)" "bash '$KS' --bogus >/dev/null 2>&1; [ \$? -eq 64 ]"

# plumbing smoke — real copy+overlay+run against the shipped example, offline (free).
# simulate can't discriminate (it fakes correct behavior) so we only assert it ran clean
# and produced the ranking table with the baseline + the example candidate.
SMOKE="$(bash "$KS" --simulate 2>&1)"
chk "simulate produces a ranking table" "printf '%s' \"\$SMOKE\" | grep -q 'KNOB SEARCH'"
chk "simulate scores the baseline"      "printf '%s' \"\$SMOKE\" | grep -q 'baseline'"
chk "simulate scores the example cand"  "printf '%s' \"\$SMOKE\" | grep -q 'example-mc-terse'"

rm -rf "$T1" "$T2" "$T3"
[ "$fail" = 0 ] && echo "PASS: knobs" || { echo "knobs test failed"; exit 1; }
