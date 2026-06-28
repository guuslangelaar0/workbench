#!/usr/bin/env bash
# workbench: cheap operational PRODUCERS for the suggestion surface. Run at SessionStart
# (and on demand) to keep the surface current. Each producer is condition-driven and
# AUTO-RESOLVES: when its condition holds it files a keyed suggestion; when the condition
# clears it removes that suggestion, so the surface never shows stale recommendations.
# (`graduate.sh` and `gate-integrity.sh`/`budget.sh` are the other producers; this covers
# the in-review cap, an empty/missing charter, and plugin-version drift.) Fails open.
#
# Usage: suggest-scan.sh [--target DIR]
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SELF_DIR/lib.sh"
SUG="$SELF_DIR/suggest.sh"
[ -x "$SUG" ] || exit 0

TARGET="$PWD"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --target) TARGET="$2"; shift 2 ;;
    *) shift ;;
  esac
done
TARGET="${TARGET%/}"; [ -n "$TARGET" ] || TARGET="/"
CFG="$(il_cfg_dir "$TARGET")/config.json"
[ -f "$CFG" ] || exit 0   # not a workbench project

# add when condition true, clear when false (auto-resolve)
producer() { # <cond:0|1> <key> <severity> <title> <why> <how>
  if [ "$1" = 1 ]; then
    bash "$SUG" add --key "$2" --severity "$3" --title "$4" --why "$5" --how "$6" --source scan --target "$TARGET" >/dev/null 2>&1 || true
  else
    bash "$SUG" clear "$2" --target "$TARGET" >/dev/null 2>&1 || true
  fi
}

# --- in-review cap ---
cap="$(sed -n 's/.*"in_review_cap"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' "$CFG" | head -1)"; [ -n "$cap" ] || cap=10
ir="$(ls -1 "$TARGET/.claude/tasks/in-review" 2>/dev/null | grep -c '\.md$' || true)"
if [ "${ir:-0}" -ge "$cap" ]; then
  producer 1 inreview-cap warn "In-review at/over cap (${ir}/${cap})" \
    "the in-review queue is full; new work should pause until it drains" \
    "verify the oldest in-review tasks (/workbench:verify <id>) until under cap"
elif [ "${ir:-0}" -ge $((cap-3)) ] && [ "$cap" -gt 3 ]; then
  producer 1 inreview-cap recommend "In-review near cap (${ir}/${cap})" \
    "the in-review queue is filling; drain soon to avoid stalling new work" \
    "verify a few in-review tasks (/workbench:verify <id>)"
else
  producer 0 inreview-cap "" "" "" ""
fi

# --- missing / empty loop charter (the north star) ---
charter="$(il_cfg_dir "$TARGET")/loop-charter.md"
charter_content=0
if [ -f "$charter" ]; then
  # "content" = at least one non-blank, non-heading, non-placeholder line
  if grep -vE '^[[:space:]]*$|^#|\{\{|TODO|<[a-z].*>|\.\.\.' "$charter" | grep -q '[A-Za-z]'; then charter_content=1; fi
fi
if [ "$charter_content" = 1 ]; then
  producer 0 charter-missing "" "" "" ""
else
  producer 1 charter-missing recommend "Write your loop charter (the north star)" \
    "the charter (.workbench/loop-charter.md) is missing or empty; without it the goal can be summarized away across compaction" \
    "fill in .workbench/loop-charter.md — goal, hard constraints, definition of done, out of scope"
fi

# --- value / north-star drift audit (cadence trigger; files its own suggestion) ---
[ -x "$SELF_DIR/value-audit.sh" ] && bash "$SELF_DIR/value-audit.sh" check --target "$TARGET" >/dev/null 2>&1 || true

# --- plugin version drift (config recorded version != installed plugin version) ---
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/.claude-plugin/plugin.json" ]; then
  pv="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$CLAUDE_PLUGIN_ROOT/.claude-plugin/plugin.json" | head -1)"
  cv="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$CFG" | head -1)"
  if [ -n "$pv" ] && [ -n "$cv" ] && [ "$pv" != "$cv" ]; then
    producer 1 plugin-upgrade recommend "workbench plugin updated ($cv → $pv)" \
      "the installed plugin version differs from what this project was scaffolded with" \
      "/workbench:upgrade to re-apply managed scaffolds non-destructively"
  else
    producer 0 plugin-upgrade "" "" "" ""
  fi
fi
exit 0
