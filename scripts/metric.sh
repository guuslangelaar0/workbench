#!/usr/bin/env bash
# workbench METRICS EVENT LOG. The loop's gates emit current STATE; scoring needs HISTORY.
# This appends one durable, greppable line per loop event to <cfg>/metrics.tsv so
# /workbench:score can compute an expectancy number over what actually happened.
#
# Line:  <epoch>\t<event>\t<task_id>\t<detail>
# Events: task_closed | task_bounced | gaming_flag | regression_red | restart | drift_due
# (token spend lives in ledger.tsv, written by budget.sh — the scorer reads both.)
#
# ALWAYS exits 0 and FAILS OPEN — a metrics write must never break a gate or a turn.
# Usage: metric.sh emit <event> [--task ID] [--detail TEXT] [--target DIR]
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SELF_DIR/lib.sh" 2>/dev/null || exit 0

CMD="${1:-}"; [ "$#" -gt 0 ] && shift
EVENT="" TASK="-" DETAIL="-" TARGET="$PWD"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --task)   TASK="${2:--}"; shift 2 ;;
    --detail) DETAIL="${2:--}"; shift 2 ;;
    --target) TARGET="${2:-$PWD}"; shift 2 ;;
    -*)       shift ;;                     # tolerate unknown flags (fail-open)
    *)        [ -z "$EVENT" ] && EVENT="$1"; shift ;;
  esac
done
[ "$CMD" = emit ] || exit 0
[ -n "$EVENT" ] || exit 0
TARGET="${TARGET%/}"; [ -n "$TARGET" ] || TARGET="/"

_cfg="$(il_cfg_dir "$TARGET")"
[ -d "$_cfg" ] || exit 0   # not a workbench project — no-op
# one-line sanitize (no tabs/newlines in fields)
clean() { printf '%s' "$1" | tr '\t\n' '  '; }
printf '%s\t%s\t%s\t%s\n' "$(date +%s)" "$(clean "$EVENT")" "$(clean "$TASK")" "$(clean "$DETAIL")" \
  >> "$_cfg/metrics.tsv" 2>/dev/null || true
exit 0
