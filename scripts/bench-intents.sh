#!/usr/bin/env bash
# workbench INTENT→BEHAVIOR CONFORMANCE BENCHMARK. This does NOT test the model's coding
# skill — it tests whether the PLUGIN'S OWN descriptions, triggers, and level presets make
# the (real, Opus) model do the right thing. Each case is a user intent + a level + an
# effect-based oracle ("did the correct behavior happen?"). When conformance drops, a
# description isn't pulling its weight — the thing we can actually fix.
#
# Cases live in test/benchmark/intents/cases/<id>/:
#   prompt        the natural-language user intent (fed to claude -p)
#   level         the workbench level to scaffold the project at
#   oracle.sh     cwd=project, env RUN_OUTPUT=<captured output>; exit 0 iff correct behavior
#   simulate.sh   cwd=project, env ROOT=<plugin>; fakes the CORRECT behavior via plugin scripts
#   setup.sh      (optional) cwd=project, env ROOT; pre-seed project state before the intent
#
# Live invocation costs API tokens and is gated by WB_BENCH=1; --simulate runs free offline.
# Usage: bench-intents.sh [--simulate] [--keep] [--only <id>]
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SELF_DIR/.." && pwd)"
CASES="$ROOT/test/benchmark/intents/cases"
SIMULATE=0 KEEP=0 ONLY=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --simulate) SIMULATE=1; shift ;;
    --keep)     KEEP=1; shift ;;
    --only)     ONLY="$2"; shift 2 ;;
    *) echo "bench-intents.sh: unknown arg '$1'" >&2; exit 64 ;;
  esac
done
[ -d "$CASES" ] || { echo "bench-intents.sh: no cases dir at $CASES" >&2; exit 1; }
if [ "$SIMULATE" = 0 ] && [ "${WB_BENCH:-0}" != 1 ]; then
  echo "bench-intents.sh: the LIVE conformance run drives a real model and COSTS API TOKENS." >&2
  echo "  set WB_BENCH=1 to run it, or use --simulate for the free offline harness check." >&2
  exit 2
fi

pass=0 total=0
for cdir in "$CASES"/*/; do
  [ -d "$cdir" ] || continue
  id="$(basename "$cdir")"
  [ -n "$ONLY" ] && [ "$ONLY" != "$id" ] && continue
  [ -f "$cdir/prompt" ] && [ -f "$cdir/oracle.sh" ] || continue
  total=$((total+1))
  level="$(tr -d ' \n' < "$cdir/level" 2>/dev/null)"; [ -n "$level" ] || level=crew
  prompt="$(cat "$cdir/prompt")"

  P="$(mktemp -d)"
  bash "$ROOT/scripts/init.sh" --name "Intent" --level "$level" --target "$P" >/dev/null 2>&1
  [ -f "$cdir/setup.sh" ] && ( cd "$P" && ROOT="$ROOT" bash "$cdir/setup.sh" ) >/dev/null 2>&1

  if [ "$SIMULATE" = 1 ]; then
    : > "$P/.run-output"   # exists first; a simulate may legitimately write to it (e.g. mc output)
    ( cd "$P" && ROOT="$ROOT" bash "$cdir/simulate.sh" ) >/dev/null 2>&1
  else
    out="$( cd "$P" && claude -p --plugin-dir "$ROOT" --dangerously-skip-permissions "$prompt" 2>/dev/null )" || true
    printf '%s' "$out" > "$P/.run-output"
  fi

  if ( cd "$P" && RUN_OUTPUT="$P/.run-output" ROOT="$ROOT" bash "$cdir/oracle.sh" ) >/dev/null 2>&1; then
    verdict="PASS"; pass=$((pass+1))
  else
    verdict="fail"
  fi
  printf '  %-22s [%-4s] %s\n' "$id" "$level" "$verdict"
  [ "$KEEP" = 1 ] && echo "      (kept: $P)" || rm -rf "$P"
done

echo "─────────────────────────────────────────────"
if [ "$total" -eq 0 ]; then echo "BENCH-INTENT: no cases"; exit 0; fi
read -r conf grade <<EOF
$(awk -v p="$pass" -v t="$total" 'BEGIN{ printf "%.0f %.0f", 100.0*p/t, 100.0*p/t }')
EOF
printf "BENCH-INTENT conformance=%d/%d  expectancy=%d  grade=%d/100\n" "$pass" "$total" "$conf" "$grade"
[ "$pass" -lt "$total" ] && echo "  ↳ a failed case = the plugin's description/trigger didn't make the model do the right thing (fixable)."
exit 0
