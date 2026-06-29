#!/usr/bin/env bash
# workbench GLOBAL REGRESSION GATE. A task passing its OWN narrow verification can still
# break something else. Before advancing a task to verified, this runs the project's FULL
# checks (config `project.checks` — e.g. ["cargo test", "bunx tsc --noEmit"]) and compares
# against the last known-green run to flag WAS-GREEN-NOW-RED. Level-scaled (enforce at
# crew/fleet, advisory at solo/pair), fails open, files a warn suggestion on red.
#
# Baseline: <cfg>/regression/last.tsv — one row per check: <hash><TAB>pass|fail<TAB>cmd
# Usage: regression-gate.sh [--target DIR]
# Exit:  0 all green / advisory / no checks / fail-open · 3 red AND level enforces · 64 usage
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SELF_DIR/lib.sh"

TARGET="$PWD"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --target) TARGET="$2"; shift 2 ;;
    -*) echo "regression-gate.sh: unknown flag '$1'" >&2; exit 64 ;;
    *)  echo "regression-gate.sh: unexpected arg '$1'" >&2; exit 64 ;;
  esac
done
TARGET="${TARGET%/}"; [ -n "$TARGET" ] || TARGET="/"
CFG="$(il_cfg_dir "$TARGET")/config.json"
[ -f "$CFG" ] || { echo "regression-gate: SKIP (no config)"; exit 0; }

# --- read project.checks (array of command strings). python3 opportunistic; skip if absent.
checks=""
if command -v python3 >/dev/null 2>&1; then
  checks="$(python3 -c '
import json,sys
try:
    c=json.load(open(sys.argv[1]))
    for cmd in (c.get("project",{}).get("checks") or []):
        if isinstance(cmd,str) and cmd.strip(): print(cmd)
except Exception: pass' "$CFG" 2>/dev/null || true)"
fi
[ -n "$checks" ] || { echo "regression-gate: SKIP (no project.checks configured — set it to run the full suite)"; exit 0; }

# --- level posture
enforce=0 level=""
level="$(sed -n 's/.*"level"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$CFG" | head -1)"
case "$level" in crew|fleet) enforce=1 ;; esac

BASE_DIR="$(il_cfg_dir "$TARGET")/regression"; mkdir -p "$BASE_DIR" 2>/dev/null || true
LAST="$BASE_DIR/last.tsv"
prior_state() { [ -f "$LAST" ] && awk -F'\t' -v h="$1" '$1==h{print $2; exit}' "$LAST" || true; }

fails="" regressed="" newrows=""
while IFS= read -r cmd; do
  [ -n "$cmd" ] || continue
  h="$(printf '%s' "$cmd" | il_hash /dev/stdin 2>/dev/null | cut -c1-12)"; [ -n "$h" ] || h="$cmd"
  if ( cd "$TARGET" && eval "$cmd" ) >/dev/null 2>&1; then
    state=pass
  else
    state=fail
    fails="${fails:+$fails, }$cmd"
    [ "$(prior_state "$h")" = pass ] && regressed="${regressed:+$regressed, }$cmd"
  fi
  newrows="${newrows}${h}	${state}	${cmd}
"
done <<< "$checks"

# update baseline to the current run
printf '%s' "$newrows" > "$LAST" 2>/dev/null || true

if [ -z "$fails" ]; then
  echo "regression-gate: all green ($(printf '%s\n' "$checks" | grep -c .) check(s))"
  exit 0
fi

# red — file a warn suggestion (recommend-only surface)
if [ -x "$SELF_DIR/suggest.sh" ]; then
  why="full-suite checks failed: ${fails}"
  [ -n "$regressed" ] && why="${why}; WAS-GREEN-NOW-RED: ${regressed}"
  bash "$SELF_DIR/suggest.sh" add --key regression --severity warn \
    --title "Regression — full suite is red${regressed:+ (something that was green broke)}" \
    --why "$why" \
    --how "bounce the task to in-development and fix the failing check(s) before verifying; this is a bug (auto-file it)" \
    --source regression --target "$TARGET" >/dev/null 2>&1 || true
fi

[ -x "$SELF_DIR/metric.sh" ] && "$SELF_DIR/metric.sh" emit regression_red --detail "${regressed:-$fails}" --target "$TARGET" >/dev/null 2>&1 || true

echo "regression-gate: RED — failed: $fails" >&2
[ -n "$regressed" ] && echo "  was-green-now-red: $regressed" >&2
if [ "$enforce" = 1 ]; then
  echo "  BLOCK (level '$level' enforces the full-suite gate)" >&2
  exit 3
fi
echo "  ADVISORY (level '${level:-unset}')" >&2
exit 0
