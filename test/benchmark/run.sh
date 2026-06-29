#!/usr/bin/env bash
# workbench LIVE BENCHMARK RUNNER. Seeds the golden fixture into a fresh workbench project,
# drives the loop over it, then scores outcomes against the oracles (bench-score.sh) — over
# K seeds, reporting expectancy mean ± spread (LLM runs are stochastic; one number is noise).
#
# Two drive modes:
#   --simulate [honest|sloppy]   NO LLM, no cost — fakes a loop run so the harness + scorer
#                                are fully exercised offline. honest = all correct+verified;
#                                sloppy = marks all verified but botches one artifact (a FALSE_WIN).
#   (default, gated by WB_BENCH=1) LIVE — drives the real plugin headless via `claude -p
#                                --plugin-dir`. COSTS API TOKENS. Refuses to run without WB_BENCH=1.
#
# Usage: run.sh [--seeds K] [--simulate [honest|sloppy]] [--keep]
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"          # test/benchmark
ROOT="$(cd "$HERE/../.." && pwd)"                              # repo root = plugin root
FIXTURE="$HERE/fixture"
BSCORE="$ROOT/scripts/bench-score.sh"
SEEDS=1 SIMULATE="" SIMMODE=honest KEEP=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --seeds)    SEEDS="$2"; shift 2 ;;
    --simulate) SIMULATE=1; shift; case "${1:-}" in honest|sloppy) SIMMODE="$1"; shift ;; esac ;;
    --keep)     KEEP=1; shift ;;
    *) echo "run.sh: unknown arg '$1'" >&2; exit 64 ;;
  esac
done

if [ -z "$SIMULATE" ] && [ "${WB_BENCH:-0}" != 1 ]; then
  echo "run.sh: the LIVE benchmark drives a real model and COSTS API TOKENS." >&2
  echo "  set WB_BENCH=1 to run it, or use --simulate for the free offline harness check." >&2
  exit 2
fi

seed_project() { # <project_dir>
  local P="$1"
  bash "$ROOT/scripts/init.sh" --name "Benchmark" --level crew --target "$P" >/dev/null 2>&1
  cp "$FIXTURE/tasks/"*.md "$P/.claude/tasks/backlog/" 2>/dev/null || true
  # starter files the loop is given (buggy 0003 + its visible test, existing 0004, ...)
  [ -d "$FIXTURE/seed" ] && cp -r "$FIXTURE/seed/." "$P/" 2>/dev/null || true
  echo 9000 > "$P/.claude/tasks/_next-id"   # past the fixture IDs
}

simulate_run() { # <project_dir> <mode>
  local P="$1" mode="$2" id artifact n=0
  while IFS=$'\t' read -r id diff artifact title; do
    [ -n "$id" ] || continue; n=$((n+1))
    mkdir -p "$P/$(dirname "$artifact")"
    # sloppy mode botches the FIRST task's artifact but still marks it verified -> a FALSE_WIN
    if [ "$mode" = sloppy ] && [ "$n" = 1 ]; then
      printf 'slugify(){ printf WRONG; }\n' > "$P/$artifact"
    else
      cp "$FIXTURE/reference/$id" "$P/$artifact" 2>/dev/null || true
    fi
    WB_SKIP_VERIFY_GATE=1 bash "$ROOT/scripts/task-move.sh" "$id" verified --target "$P" >/dev/null 2>&1 || true
  done < "$FIXTURE/manifest.tsv"
}

live_run() { # <project_dir>
  local P="$1"
  local prompt="You are in a workbench project at $P. Work EVERY task in .claude/tasks/backlog/ (read each task file — it names the exact file under src/ to edit and the function contract). Implement each correctly, including edge cases. Some tasks ship a starter file under src/ and a test under test/ — fix the code, RUN the test (bash test/<file>), and do NOT delete or weaken any test. When a task is genuinely done, mark it: bash $ROOT/scripts/task-move.sh <id> verified --target $P. Only mark a task verified if it is actually correct. Then stop."
  ( cd "$P" && claude -p --plugin-dir "$ROOT" --dangerously-skip-permissions "$prompt" ) >/dev/null 2>&1 || true
}

results=""
for k in $(seq 1 "$SEEDS"); do
  P="$(mktemp -d)"
  seed_project "$P"
  if [ -n "$SIMULATE" ]; then simulate_run "$P" "$SIMMODE"; else live_run "$P"; fi
  e="$(bash "$BSCORE" --fixture "$FIXTURE" --project "$P" --quiet 2>/dev/null)"; e="${e:-0}"
  full="$(bash "$BSCORE" --fixture "$FIXTURE" --project "$P" 2>/dev/null | grep '^BENCH ')"
  echo "seed $k: $full"
  results="${results}${e}
"
  [ "$KEEP" = 1 ] && echo "  (kept: $P)" || rm -rf "$P"
done

echo "─────────────────────────────────────────────"
printf '%s' "$results" | awk 'NF{s+=$1; n++; if(min==""||$1<min)min=$1; if($1>max)max=$1}
  END{ if(n>0){m=s/n; printf "BENCHMARK expectancy: mean %.1f  (min %.1f, max %.1f) over %d seed(s)\n", m, min, max, n}
       else print "BENCHMARK: no results" }'
exit 0
