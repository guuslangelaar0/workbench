#!/usr/bin/env bash
# Deterministic health check for a project scaffolded by workbench.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SELF_DIR/lib.sh"
TARGET="$PWD"

need_arg() { [ "$#" -ge 2 ] || { echo "doctor.sh: $1 requires a value" >&2; exit 64; }; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --target) need_arg "$@"; TARGET="$2"; shift 2 ;;
    *) echo "doctor.sh: unknown arg '$1'" >&2; exit 64 ;;
  esac
done

CFG="$(il_cfg_dir "$TARGET")/config.json"
MANIFEST="$(il_cfg_dir "$TARGET")/manifest.json"
# python3 backs the JSON checks, the drift inventory, and the task rollup; fail cleanly if
# it's absent rather than aborting mid-report under set -e (matches scripts/drift.sh).
command -v python3 >/dev/null 2>&1 || { echo "doctor: python3 is required for the health check but was not found on PATH." >&2; exit 3; }

echo "workbench doctor -- $TARGET"

json_status() {
  local label="$1" path="$2"
  if [ ! -f "$path" ]; then
    printf '%s: missing (%s)\n' "$label" "$path"
    return 1
  fi
  if python3 -m json.tool "$path" >/dev/null 2>&1; then
    printf '%s: ok\n' "$label"
    return 0
  fi
  printf '%s: invalid json (%s)\n' "$label" "$path"
  return 1
}

json_status "Config" "$CFG" || true
json_status "Manifest" "$MANIFEST" || true

echo "Drift:"
if [ -f "$MANIFEST" ]; then
  bash "$SELF_DIR/upgrade.sh" --target "$TARGET" --dry-run | sed 's/^/  /'
else
  echo "  skipped (manifest missing)"
fi

echo "Hooks:"
PRECOMMIT="$TARGET/.git/hooks/pre-commit"
if [ -f "$PRECOMMIT" ] && grep -q 'wb-coord commit guard' "$PRECOMMIT"; then
  echo "  pre-commit: installed"
else
  echo "  pre-commit: missing"
fi
if [ -f "$TARGET/.gitignore" ] && grep -qxF '/.claude/locks/' "$TARGET/.gitignore"; then
  echo "  gitignore: locks ignored"
else
  echo "  gitignore: locks not ignored"
fi

echo "Lanes:"
if [ -x "$SELF_DIR/lane.sh" ]; then
  lane_out="$(bash "$SELF_DIR/lane.sh" list --target "$TARGET" 2>/dev/null || true)"
  if [ -n "$lane_out" ]; then printf '%s\n' "$lane_out" | sed 's/^/  /'; else echo "  none"; fi
  reap_out="$(bash "$SELF_DIR/lane.sh" reap --target "$TARGET" 2>/dev/null || true)"
  if [ -n "$reap_out" ]; then printf '%s\n' "$reap_out" | sed 's/^/  stale: /'; fi
else
  echo "  lane.sh missing"
fi

echo "Dependencies:"
if [ -x "$SELF_DIR/deps.sh" ] && [ -d "$TARGET/.claude/tasks" ]; then
  bash "$SELF_DIR/deps.sh" blocked --target "$TARGET" 2>/dev/null | sed 's/^/  blocked: /' || true
  bash "$SELF_DIR/deps.sh" cycles --target "$TARGET" 2>/dev/null | sed 's/^/  cycles: /' || true
else
  echo "  unavailable"
fi

echo "Tasks:"
python3 - "$TARGET" "$CFG" <<'PY'
import json
import os
import sys

target, cfg_path = sys.argv[1:3]
task_root = os.path.join(target, ".claude", "tasks")
states = []
if os.path.isdir(task_root):
    states = sorted([n for n in os.listdir(task_root) if os.path.isdir(os.path.join(task_root, n))])
for base in ["backlog", "in-development", "in-review", "verified", "decisions"]:
    if base not in states:
        states.append(base)

counts = {}
for state in states:
    root = os.path.join(task_root, state)
    counts[state] = len([n for n in os.listdir(root) if n.endswith(".md")]) if os.path.isdir(root) else 0

cap = None
if os.path.exists(cfg_path):
    try:
        cap = json.load(open(cfg_path)).get("lifecycle", {}).get("in_review_cap")
    except Exception:
        cap = None

for state in states:
    suffix = ""
    if state == "in-review" and isinstance(cap, int):
        suffix = f" / cap {cap}"
        if counts[state] >= cap:
            suffix += " (at-or-over)"
    print(f"  {state}: {counts[state]}{suffix}")
PY

SESSION="$TARGET/.claude/SESSION_STATE.md"
if [ -f "$SESSION" ]; then
  if stat -c %y "$SESSION" >/dev/null 2>&1; then
    echo "SessionState: $(stat -c %y "$SESSION" | cut -d. -f1)"
  else
    echo "SessionState: $(stat -f '%Sm' "$SESSION")"
  fi
else
  echo "SessionState: missing"
fi

if [ -f "$TARGET/.workbench/loop-charter.md" ]; then
  echo "Charter: present"
else
  echo "Charter: missing"
fi
