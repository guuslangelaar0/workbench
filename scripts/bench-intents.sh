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
# Each case is tagged train|holdout via a `set` file (default train). The knob search (BM-6)
# optimizes against the TRAIN set; HOLDOUT is reserved to validate a proposed winner so we
# can't overfit the metric (Goodhart, §5.4 of the design). --set picks which subset to run.
#
# Live invocation costs API tokens and is gated by WB_BENCH=1; --simulate runs free offline.
# Usage: bench-intents.sh [--simulate] [--keep] [--only <id>] [--set train|holdout|all]
# Env:
#   WB_BENCH_TIMEOUT=300  live per-case timeout in seconds
#   WB_BENCH_ATTEMPTS=1   live attempts per case; release gate uses 2
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SELF_DIR/.." && pwd)"
CASES="$ROOT/test/benchmark/intents/cases"
SIMULATE=0 KEEP=0 ONLY="" SET="all"
LIVE_TIMEOUT="${WB_BENCH_TIMEOUT:-300}"
LIVE_ATTEMPTS="${WB_BENCH_ATTEMPTS:-1}"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --simulate) SIMULATE=1; shift ;;
    --keep)     KEEP=1; shift ;;
    --only)     ONLY="$2"; shift 2 ;;
    --set)      SET="$2"; shift 2 ;;
    *) echo "bench-intents.sh: unknown arg '$1'" >&2; exit 64 ;;
  esac
done
case "$SET" in train|holdout|all) ;; *) echo "bench-intents.sh: --set must be train|holdout|all (got '$SET')" >&2; exit 64 ;; esac
case "$LIVE_TIMEOUT" in ''|*[!0-9]*) echo "bench-intents.sh: WB_BENCH_TIMEOUT must be a positive integer" >&2; exit 64 ;; esac
[ "$LIVE_TIMEOUT" -gt 0 ] || { echo "bench-intents.sh: WB_BENCH_TIMEOUT must be a positive integer" >&2; exit 64; }
case "$LIVE_ATTEMPTS" in ''|*[!0-9]*) echo "bench-intents.sh: WB_BENCH_ATTEMPTS must be a positive integer" >&2; exit 64 ;; esac
[ "$LIVE_ATTEMPTS" -gt 0 ] || { echo "bench-intents.sh: WB_BENCH_ATTEMPTS must be a positive integer" >&2; exit 64; }
[ -d "$CASES" ] || { echo "bench-intents.sh: no cases dir at $CASES" >&2; exit 1; }
if [ "$SIMULATE" = 0 ] && [ "${WB_BENCH:-0}" != 1 ]; then
  echo "bench-intents.sh: the LIVE conformance run drives a real model and COSTS API TOKENS." >&2
  echo "  set WB_BENCH=1 to run it, or use --simulate for the free offline harness check." >&2
  exit 2
fi

pass=0 total=0 timeouts=0 failures=0
for cdir in "$CASES"/*/; do
  [ -d "$cdir" ] || continue
  id="$(basename "$cdir")"
  [ -n "$ONLY" ] && [ "$ONLY" != "$id" ] && continue
  [ -f "$cdir/prompt" ] && [ -f "$cdir/oracle.sh" ] || continue
  cset="$(tr -d ' \n' < "$cdir/set" 2>/dev/null)"; [ -n "$cset" ] || cset="train"
  [ "$SET" != "all" ] && [ "$SET" != "$cset" ] && continue
  total=$((total+1))
  level="$(tr -d ' \n' < "$cdir/level" 2>/dev/null)"; [ -n "$level" ] || level=crew
  prompt="$(cat "$cdir/prompt")"
  attempts=1
  [ "$SIMULATE" = 0 ] && attempts="$LIVE_ATTEMPTS"
  attempt=1
  verdict=""
  kept_path=""

  while [ "$attempt" -le "$attempts" ]; do
    timed_out=0

    P="$(mktemp -d)"
    # seed a concrete mission so cases test intent ROUTING, not cold-start ambiguity
    # (a blank project makes the model ask clarifying questions instead of acting).
    bash "$ROOT/scripts/init.sh" --name "Intent" --level "$level" \
      --mission "A small web product: a public REST API, a web UI, and a settings page." \
      --target "$P" >/dev/null 2>&1
    [ -f "$cdir/setup.sh" ] && ( cd "$P" && ROOT="$ROOT" bash "$cdir/setup.sh" ) >/dev/null 2>&1

    if [ "$SIMULATE" = 1 ]; then
      : > "$P/.run-output"   # exists first; a simulate may legitimately write to it (e.g. mc output)
      ( cd "$P" && ROOT="$ROOT" bash "$cdir/simulate.sh" ) >/dev/null 2>&1
    else
      out="$( cd "$P" && timeout "$LIVE_TIMEOUT" claude -p --plugin-dir "$ROOT" --dangerously-skip-permissions "$prompt" 2>/dev/null )"
      live_rc=$?
      if [ "$live_rc" -eq 124 ]; then
        timed_out=1
        out="TIMEOUT after ${LIVE_TIMEOUT}s: $prompt"
      elif [ "$live_rc" -ne 0 ]; then
        out="${out}
CLAUDE_EXIT_${live_rc}"
      fi
      printf '%s' "$out" > "$P/.run-output"
    fi

    if ( cd "$P" && RUN_OUTPUT="$P/.run-output" ROOT="$ROOT" bash "$cdir/oracle.sh" ) >/dev/null 2>&1; then
      verdict="PASS"
      pass=$((pass+1))
      [ "$KEEP" = 1 ] && kept_path="$P" || rm -rf "$P"
      break
    elif [ "$timed_out" = 1 ]; then
      verdict="TIMEOUT"
    else
      verdict="fail"
    fi

    if [ "$attempt" -lt "$attempts" ]; then
      rm -rf "$P"
      attempt=$((attempt+1))
      continue
    fi

    [ "$verdict" = "TIMEOUT" ] && timeouts=$((timeouts+1)) || failures=$((failures+1))
    [ "$KEEP" = 1 ] && kept_path="$P" || rm -rf "$P"
    break
  done

  retry_note=""
  [ "$attempt" -gt 1 ] && retry_note=" (attempt $attempt/$attempts)"
  printf '  %-22s [%-4s] %s%s\n' "$id" "$level" "$verdict" "$retry_note"
  [ "$KEEP" = 1 ] && [ -n "$kept_path" ] && echo "      (kept: $kept_path)"
done

echo "─────────────────────────────────────────────"
if [ "$total" -eq 0 ]; then echo "BENCH-INTENT: no cases"; exit 0; fi
read -r conf grade <<EOF
$(awk -v p="$pass" -v t="$total" 'BEGIN{ printf "%.0f %.0f", 100.0*p/t, 100.0*p/t }')
EOF
printf "BENCH-INTENT [set=%s] conformance=%d/%d  expectancy=%d  grade=%d/100\n" "$SET" "$pass" "$total" "$conf" "$grade"
if [ "$timeouts" -gt 0 ]; then
  echo "  ↳ a timed-out case = the live model call exceeded WB_BENCH_TIMEOUT before the oracle could evaluate behavior."
fi
if [ "$failures" -gt 0 ]; then
  echo "  ↳ a failed case = the plugin's description/trigger didn't make the model do the right thing (fixable)."
fi
exit 0
