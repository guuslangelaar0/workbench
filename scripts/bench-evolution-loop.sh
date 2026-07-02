#!/usr/bin/env bash
# workbench EVOLUTION-LOOP CONFORMANCE BENCHMARK. Same shape as scripts/bench-intents.sh
# (a natural-language prompt + an effect-based oracle reading real project-FS ground
# truth), applied to the evolution-loop "summit" mechanism instead of ordinary intent
# routing: does the persona panel actually synthesize well-formed tasks, does the critic
# actually reject bad ideas, does the retrospective ledger-grep actually dedup, does the
# trigger condition actually fire/not-fire.
#
# Cases live in test/benchmark/evolution-loop/cases/<id>/:
#   prompt.md    the natural-language instruction to run a summit now (fed to claude -p)
#   oracle.sh    cwd=project, env RUN_OUTPUT=<captured output>, FIXTURE=<fixture dir>;
#                exit 0 iff correct behavior
#   simulate.sh  cwd=project, env ROOT=<plugin>, FIXTURE=<fixture dir>; fakes the
#                CORRECT behavior directly against fixture task files (no LLM, no cost)
#   variant.sh   (optional) cwd=project; mutates the seeded fixture copy for this case
#                (e.g. shrinks the backlog, ages last_summit_at, plants a bad idea)
#
# ASSUMPTIONS this suite makes about the not-yet-landed implementation are recorded in
# test/benchmark/evolution-loop/cases/README.md — read that before trusting a failure.
#
# Usage: bench-evolution-loop.sh [--simulate] [--keep] [--only <id>]
# Env:   WB_BENCH=1 required for the live (non --simulate) path (costs API tokens)
#        WB_BENCH_TIMEOUT=600  live per-case timeout in seconds (summits read more
#                               context than a routing intent, so the default is
#                               longer than bench-intents.sh's 300s)
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SELF_DIR/.." && pwd)"
SUITE="$ROOT/test/benchmark/evolution-loop"
CASES="$SUITE/cases"
FIXTURE="$SUITE/fixture/project-a"
LIVE_TIMEOUT="${WB_BENCH_TIMEOUT:-600}"

SIMULATE=0 KEEP=0 ONLY=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --simulate) SIMULATE=1; shift ;;
    --keep)     KEEP=1; shift ;;
    --only)     ONLY="$2"; shift 2 ;;
    *) echo "bench-evolution-loop.sh: unknown arg '$1'" >&2; exit 64 ;;
  esac
done
[ -d "$CASES" ]   || { echo "bench-evolution-loop.sh: no cases dir at $CASES" >&2; exit 1; }
[ -d "$FIXTURE" ] || { echo "bench-evolution-loop.sh: no fixture at $FIXTURE" >&2; exit 1; }
if [ "$SIMULATE" = 0 ] && [ "${WB_BENCH:-0}" != 1 ]; then
  echo "bench-evolution-loop.sh: the LIVE run drives a real model and COSTS API TOKENS." >&2
  echo "  set WB_BENCH=1 to run it, or use --simulate for the free offline harness check." >&2
  exit 2
fi

pass=0 total=0 failures=0
for cdir in "$CASES"/*/; do
  [ -d "$cdir" ] || continue
  id="$(basename "$cdir")"
  [ "$id" = "lib.sh" ] && continue
  [ -n "$ONLY" ] && [ "$ONLY" != "$id" ] && continue
  [ -f "$cdir/prompt.md" ] && [ -f "$cdir/oracle.sh" ] || continue
  total=$((total+1))

  P="$(mktemp -d)"
  cp -r "$FIXTURE/." "$P/"
  [ -f "$cdir/variant.sh" ] && ( cd "$P" && FIXTURE="$FIXTURE" ROOT="$ROOT" bash "$cdir/variant.sh" ) >/dev/null 2>&1

  if [ "$SIMULATE" = 1 ]; then
    : > "$P/.run-output"
    ( cd "$P" && ROOT="$ROOT" FIXTURE="$FIXTURE" bash "$cdir/simulate.sh" ) >/dev/null 2>&1
  else
    prompt="$(cat "$cdir/prompt.md")"
    out="$( cd "$P" && timeout "$LIVE_TIMEOUT" claude -p --plugin-dir "$ROOT" --dangerously-skip-permissions "$prompt" 2>/dev/null )"
    rc=$?
    [ "$rc" -eq 124 ] && out="TIMEOUT after ${LIVE_TIMEOUT}s"
    printf '%s' "$out" > "$P/.run-output"
  fi

  if ( cd "$P" && RUN_OUTPUT="$P/.run-output" ROOT="$ROOT" FIXTURE="$FIXTURE" bash "$cdir/oracle.sh" ) >/dev/null 2>&1; then
    verdict="PASS"; pass=$((pass+1))
  else
    verdict="fail"; failures=$((failures+1))
  fi

  printf '  %-28s %s\n' "$id" "$verdict"
  if [ "$KEEP" = 1 ]; then echo "      (kept: $P)"; else rm -rf "$P"; fi
done

echo "─────────────────────────────────────────────"
if [ "$total" -eq 0 ]; then echo "BENCH-EVOLUTION-LOOP: no cases"; exit 0; fi
grade="$(awk -v p="$pass" -v t="$total" 'BEGIN{ printf "%.0f", 100.0*p/t }')"
printf "BENCH-EVOLUTION-LOOP conformance=%d/%d  grade=%d/100\n" "$pass" "$total" "$grade"
if [ "$failures" -gt 0 ]; then
  echo "  ↳ a failed case = the summit mechanism didn't do the right thing — see cases/README.md for what each case checks and any implementation assumptions baked into its oracle."
fi
exit 0
