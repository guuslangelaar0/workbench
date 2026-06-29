#!/usr/bin/env bash
# workbench VALUE / NORTH-STAR DRIFT AUDIT. Over days a loop can do technically-correct
# but low-value work, or scope-creep away from the goal. This is a CADENCE TRIGGER, not a
# judge: bash can't decide "is this drifting?", so when enough tasks have closed since the
# last audit it surfaces the DATA PACKET (recent closes + the charter's goal) as a
# recommend-only suggestion, and the loop/human makes the call. Auto-resolves when not due.
#
# Storage: <cfg>/audit/last-count (closes at the last audit). Cadence: --cadence N | config
# `audit.cadence` | default 6.
# Usage:
#   value-audit.sh check [--cadence N] [--target DIR]   file/clear the "audit due" suggestion
#   value-audit.sh done  [--target DIR]                 record this audit as done (resets cadence)
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SELF_DIR/lib.sh"
SUG="$SELF_DIR/suggest.sh"

CMD="${1:-}"; [ "$#" -gt 0 ] && shift
TARGET="$PWD" CADENCE=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --target)  TARGET="$2"; shift 2 ;;
    --cadence) CADENCE="$2"; shift 2 ;;
    -*) echo "value-audit.sh: unknown flag '$1'" >&2; exit 64 ;;
    *)  shift ;;
  esac
done
TARGET="${TARGET%/}"; [ -n "$TARGET" ] || TARGET="/"
CFG="$(il_cfg_dir "$TARGET")/config.json"
[ -f "$CFG" ] || { echo "value-audit: SKIP (no config)"; exit 0; }
T="$TARGET/.claude/tasks"
ADIR="$(il_cfg_dir "$TARGET")/audit"; LASTF="$ADIR/last-count"

closes() { find "$T/verified" "$T/shipped" -maxdepth 1 -name '*.md' -type f 2>/dev/null | grep -c . || true; }

case "$CMD" in
  done)
    mkdir -p "$ADIR" 2>/dev/null || true
    closes > "$LASTF" 2>/dev/null || true
    [ -x "$SUG" ] && bash "$SUG" clear value-audit --target "$TARGET" >/dev/null 2>&1 || true
    echo "value-audit: recorded ($(closes) closes) — cadence reset"
    ;;
  check|"" )
    done_n="$(closes)"; done_n="${done_n:-0}"
    last_n=0; [ -f "$LASTF" ] && last_n="$(tr -d ' \n' < "$LASTF" 2>/dev/null)"; case "$last_n" in ''|*[!0-9]*) last_n=0 ;; esac
    cad="$CADENCE"; [ -n "$cad" ] || cad="$(sed -n 's/.*"cadence"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' "$CFG" | head -1)"; [ -n "$cad" ] || cad=6
    delta=$(( done_n - last_n )); [ "$delta" -lt 0 ] && delta=0

    if [ "$delta" -lt "$cad" ]; then
      [ -x "$SUG" ] && bash "$SUG" clear value-audit --target "$TARGET" >/dev/null 2>&1 || true
      echo "value-audit: not due ($delta/$cad closes since last)"
      exit 0
    fi

    # gather the data packet for the judgment
    recent="$(find "$T/verified" "$T/shipped" -maxdepth 1 -name '*.md' -type f 2>/dev/null \
      | sort | tail -n "$cad" \
      | while IFS= read -r f; do head -1 "$f" | sed 's/^# *//'; done \
      | awk '{printf "%s%s", sep, $0; sep="; "} END{print ""}')"
    goal=""
    charter="$(il_cfg_dir "$TARGET")/loop-charter.md"
    if [ -f "$charter" ]; then
      goal="$(awk '/^##[[:space:]]*Goal/{f=1;next} /^##/{f=0} f && NF{print; exit}' "$charter")"
      [ -n "$goal" ] || goal="$(grep -vE '^[[:space:]]*$|^#' "$charter" | head -1)"
    fi

    if [ -x "$SUG" ]; then
      bash "$SUG" add --key value-audit --severity recommend \
        --title "Value/north-star drift audit due ($delta closes since last)" \
        --why "recent closes: ${recent:-(none parsed)} | charter goal: ${goal:-(charter empty)}" \
        --how "compare the recent closes against the charter goal + roadmap; re-prioritize the backlog if work is drifting low-value, then run: value-audit.sh done" \
        --source value-audit --target "$TARGET" >/dev/null 2>&1 || true
    fi
    [ -x "$SELF_DIR/metric.sh" ] && "$SELF_DIR/metric.sh" emit drift_due --detail "$delta closes" --target "$TARGET" >/dev/null 2>&1 || true
    echo "value-audit: DUE ($delta/$cad) — filed a recommend suggestion"
    ;;
  *)
    echo "value-audit.sh: unknown subcommand '$CMD' (check|done)" >&2; exit 64 ;;
esac
exit 0
