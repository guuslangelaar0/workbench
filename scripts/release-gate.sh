#!/usr/bin/env bash
# Workbench release gate. Runs the offline release checks by default and, with
# --live, proves the plugin through the real Claude Code live E2E/bench layers.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIVE=0
LIVE_CODING=0
DRY_RUN=0
RUN_SUITE=1
RUN_RUST=1
RUN_OFFLINE_BENCH=1
WRITE_EVIDENCE=1
SET="all"
SEEDS=1
EVIDENCE=""

usage() {
  cat <<'USAGE'
Usage: bash scripts/release-gate.sh [options]

Options:
  --live              Run required live plugin gates:
                        WB_E2E=1 test/e2e/run.sh
                        WB_BENCH=1 scripts/bench.sh
  --live-coding       Also run the live coding oracle benchmark.
  --set <set>         Intent benchmark set: train, holdout, or all (default: all).
  --seeds <n>         Seeds for --live-coding benchmark (default: 1).
  --skip-suite        Skip bash test/all.sh.
  --skip-rust         Skip cargo fmt/test/build gates.
  --skip-offline-bench
                      Skip scripts/bench.sh offline simulate gate.
  --evidence <path>   Write release evidence JSON to this path.
  --no-evidence       Do not write evidence JSON/log files.
  --dry-run           Print the planned commands without running them.
  -h, --help          Show this help.

Environment overrides for tests:
  WB_RELEASE_E2E_CMD
  WB_RELEASE_BENCH_LIVE_CMD
  WB_RELEASE_LIVE_CODING_CMD
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --live) LIVE=1; shift ;;
    --live-coding) LIVE=1; LIVE_CODING=1; shift ;;
    --set) SET="${2:-}"; shift 2 ;;
    --seeds) SEEDS="${2:-}"; shift 2 ;;
    --skip-suite) RUN_SUITE=0; shift ;;
    --skip-rust) RUN_RUST=0; shift ;;
    --skip-offline-bench) RUN_OFFLINE_BENCH=0; shift ;;
    --evidence) EVIDENCE="${2:-}"; shift 2 ;;
    --no-evidence) WRITE_EVIDENCE=0; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "release-gate.sh: unknown arg '$1'" >&2; exit 64 ;;
  esac
done

case "$SET" in train|holdout|all) ;; *) echo "release-gate.sh: --set must be train|holdout|all (got '$SET')" >&2; exit 64 ;; esac
case "$SEEDS" in ''|*[!0-9]*) echo "release-gate.sh: --seeds must be a positive integer" >&2; exit 64 ;; esac
[ "$SEEDS" -gt 0 ] || { echo "release-gate.sh: --seeds must be a positive integer" >&2; exit 64; }

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
HEAD_SHA="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || true)"
BRANCH="$(git -C "$ROOT" branch --show-current 2>/dev/null || true)"

if [ -z "$EVIDENCE" ]; then
  EVIDENCE="$ROOT/.workbench/release/live-gate-$RUN_ID.json"
fi
LOG_DIR="${EVIDENCE%.json}.logs"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/workbench-release-gate.XXXXXX")"
RESULTS="$TMP/results.tsv"
: > "$RESULTS"
trap 'rm -rf "$TMP"' EXIT

rc=0
planned=0

record_step() {
  # key label command status verdict proof output started ended
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$@" >> "$RESULTS"
}

require_e2e_pass() {
  local out="$1"
  if grep -q '^SKIP:' "$out"; then
    echo "release-gate: live E2E was requested but skipped" >&2
    return 1
  fi
  if ! grep -q 'E2E PASS' "$out"; then
    echo "release-gate: live E2E did not report E2E PASS" >&2
    return 1
  fi
}

require_live_bench_pass() {
  local out="$1" line pass total
  if grep -q 'LIVE .*skipped\|LIVE — skipped\|SKIP:' "$out"; then
    echo "release-gate: live bench was requested but skipped" >&2
    return 1
  fi
  line="$(grep 'BENCH-INTENT .*conformance=' "$out" | tail -1)"
  if [ -z "$line" ]; then
    echo "release-gate: live bench did not print BENCH-INTENT conformance" >&2
    return 1
  fi
  pass="$(printf '%s\n' "$line" | sed -n 's/.*conformance=\([0-9][0-9]*\)\/\([0-9][0-9]*\).*/\1/p')"
  total="$(printf '%s\n' "$line" | sed -n 's/.*conformance=\([0-9][0-9]*\)\/\([0-9][0-9]*\).*/\2/p')"
  if [ -z "$pass" ] || [ -z "$total" ] || [ "$pass" != "$total" ]; then
    echo "release-gate: live bench was not perfect ($line)" >&2
    return 1
  fi
}

require_coding_bench_ran() {
  local out="$1"
  if grep -q 'LIVE .*COSTS API TOKENS\|set WB_BENCH=1' "$out"; then
    echo "release-gate: live coding benchmark was requested but refused to run" >&2
    return 1
  fi
  if ! grep -q 'BENCHMARK expectancy:' "$out"; then
    echo "release-gate: live coding benchmark did not print expectancy" >&2
    return 1
  fi
}

run_step() {
  local key="$1" label="$2" proof="$3" cmd="$4"
  local out="$TMP/$key.out" started ended status verdict
  echo
  echo "== $label =="
  echo "+ $cmd"
  if [ "$DRY_RUN" = 1 ]; then
    planned=$((planned+1))
    record_step "$key" "$label" "$cmd" "0" "planned" "$proof" "" "" ""
    return 0
  fi

  started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  bash -c "$cmd" >"$out" 2>&1
  status=$?
  ended="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  cat "$out"

  verdict="pass"
  if [ "$status" -ne 0 ]; then
    verdict="fail"
  else
    case "$proof" in
      e2e) require_e2e_pass "$out" || verdict="fail" ;;
      live-bench) require_live_bench_pass "$out" || verdict="fail" ;;
      coding-bench) require_coding_bench_ran "$out" || verdict="fail" ;;
      bench) grep -q 'bench: OK' "$out" || verdict="fail" ;;
      none) ;;
      *) echo "release-gate.sh: unknown proof '$proof'" >&2; verdict="fail" ;;
    esac
  fi

  if [ "$verdict" != "pass" ]; then
    rc=1
    echo "release-gate: FAILED $label" >&2
  fi
  record_step "$key" "$label" "$cmd" "$status" "$verdict" "$proof" "$out" "$started" "$ended"
}

maybe_claude_plugin_validate() {
  if command -v claude >/dev/null 2>&1; then
    run_step "claude_plugin_validate" "Claude plugin validate" "none" "claude plugin validate '$ROOT'"
  else
    echo
    echo "== Claude plugin validate =="
    echo "SKIP: claude CLI not found on PATH"
    record_step "claude_plugin_validate" "Claude plugin validate" "claude plugin validate '$ROOT'" "0" "skipped" "none" "" "" ""
  fi
}

echo "═══ workbench release gate ═══"
echo "branch: ${BRANCH:-unknown}"
echo "head: ${HEAD_SHA:-unknown}"
echo "live: $LIVE"

if [ "$RUN_RUST" = 1 ]; then
  run_step "cargo_fmt" "Rust formatting" "none" "cd '$ROOT' && cargo fmt --check"
  run_step "cargo_test" "Rust workspace tests" "none" "cd '$ROOT' && cargo test --workspace"
  run_step "cargo_build_mesh" "Build mesh binary" "none" "cd '$ROOT' && cargo build -p workbench-mesh"
else
  echo
  echo "== Rust gates =="
  echo "SKIP: --skip-rust"
fi

if [ "$RUN_SUITE" = 1 ]; then
  run_step "offline_suite" "Offline suite" "none" "cd '$ROOT' && bash test/all.sh"
else
  echo
  echo "== Offline suite =="
  echo "SKIP: --skip-suite"
fi

run_step "publishability" "Publishability validator" "none" "cd '$ROOT' && bash scripts/validate-plugin.sh"
maybe_claude_plugin_validate

if [ "$RUN_OFFLINE_BENCH" = 1 ]; then
  run_step "bench_offline" "Offline bench" "bench" "cd '$ROOT' && bash scripts/bench.sh --set '$SET'"
else
  echo
  echo "== Offline bench =="
  echo "SKIP: --skip-offline-bench"
fi

if [ "$LIVE" = 1 ]; then
  e2e_cmd="${WB_RELEASE_E2E_CMD:-cd '$ROOT' && WB_E2E=1 bash test/e2e/run.sh}"
  bench_cmd="${WB_RELEASE_BENCH_LIVE_CMD:-cd '$ROOT' && WB_BENCH=1 bash scripts/bench-intents.sh --set '$SET'}"
  run_step "live_e2e" "Live plugin E2E" "e2e" "$e2e_cmd"
  run_step "live_bench" "Live intent bench" "live-bench" "$bench_cmd"
else
  echo
  echo "== Live gates =="
  echo "SKIP: pass --live to run WB_E2E=1 and WB_BENCH=1 live gates"
fi

if [ "$LIVE_CODING" = 1 ]; then
  coding_cmd="${WB_RELEASE_LIVE_CODING_CMD:-cd '$ROOT' && WB_BENCH=1 bash test/benchmark/run.sh --seeds '$SEEDS'}"
  run_step "live_coding_benchmark" "Live coding oracle benchmark" "coding-bench" "$coding_cmd"
fi

if [ "$WRITE_EVIDENCE" = 1 ] && [ "$DRY_RUN" = 0 ]; then
  mkdir -p "$(dirname "$EVIDENCE")" "$LOG_DIR"
  while IFS=$'\t' read -r key label cmd status verdict proof out started ended; do
    [ -n "$out" ] && [ -f "$out" ] && cp "$out" "$LOG_DIR/$key.log"
  done < "$RESULTS"
  python3 - "$RESULTS" "$EVIDENCE" "$LOG_DIR" "$ROOT" "$RUN_ID" "$BRANCH" "$HEAD_SHA" "$LIVE" "$LIVE_CODING" "$SET" "$SEEDS" "$rc" <<'PY'
import json
import os
import sys

results, evidence, log_dir, root, run_id, branch, head, live, live_coding, bench_set, seeds, rc = sys.argv[1:13]
steps = []
with open(results, encoding="utf-8") as f:
    for raw in f:
        raw = raw.rstrip("\n")
        if not raw:
            continue
        key, label, command, status, verdict, proof, output, started, ended = raw.split("\t")
        log_path = ""
        if output:
            candidate = os.path.join(log_dir, f"{key}.log")
            if os.path.exists(candidate):
                log_path = os.path.relpath(candidate, root)
        steps.append({
            "key": key,
            "label": label,
            "command": command,
            "exit_code": int(status),
            "verdict": verdict,
            "proof": proof,
            "started_at": started or None,
            "ended_at": ended or None,
            "log": log_path or None,
        })

payload = {
    "schema": "workbench.release_gate.v1",
    "run_id": run_id,
    "generated_at": run_id,
    "repo": root,
    "branch": branch or None,
    "head": head or None,
    "live_requested": live == "1",
    "live_coding_requested": live_coding == "1",
    "bench_set": bench_set,
    "coding_seeds": int(seeds),
    "verdict": "pass" if rc == "0" else "fail",
    "steps": steps,
}
with open(evidence, "w", encoding="utf-8") as f:
    json.dump(payload, f, indent=2)
    f.write("\n")
PY
  echo
  echo "evidence: $EVIDENCE"
fi

echo
echo "═══════════════════════════════════════"
if [ "$DRY_RUN" = 1 ]; then
  echo "release-gate: DRY RUN ($planned planned checks)"
  exit 0
fi

[ "$rc" = 0 ] && echo "release-gate: PASS" || echo "release-gate: FAILED"
exit "$rc"
