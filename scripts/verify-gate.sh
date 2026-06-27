#!/usr/bin/env bash
# workbench verification-contract checker.
#
# Given a task file, decides whether it satisfies the contract — real acceptance
# criteria AND captured verification evidence — and whether an unmet contract should
# BLOCK, scaled by the project's level (enforce at crew/fleet; advisory at solo/pair).
#
# Pure bash + awk: no python, no jq, so the hooks and task-move.sh can call it fast
# and it FAILS OPEN (exit 0) on anything unexpected — it never blocks a non-workbench
# session or errors a user's turn.
#
# Usage: verify-gate.sh <task-file> [--target DIR]
# Exit:  0  ok, OR advisory-only (failing but level is advisory), OR fail-open
#        3  contract unmet AND the level enforces  -> caller should block
#        64 usage error
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SELF_DIR/lib.sh"

FILE="" TARGET="$PWD"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --target) [ "$#" -ge 2 ] || { echo "verify-gate.sh: --target requires a value" >&2; exit 64; }; TARGET="$2"; shift 2 ;;
    -*) echo "verify-gate.sh: unknown flag '$1'" >&2; exit 64 ;;
    *) if [ -z "$FILE" ]; then FILE="$1"; else echo "verify-gate.sh: too many args" >&2; exit 64; fi; shift ;;
  esac
done
[ -n "$FILE" ] || { echo "verify-gate.sh: usage: verify-gate.sh <task-file> [--target DIR]" >&2; exit 64; }
TARGET="${TARGET%/}"; [ -n "$TARGET" ] || TARGET="/"
# fail open if the task file is unreadable
[ -f "$FILE" ] || { echo "verify-gate: SKIP (no task file: $FILE)"; exit 0; }

# --- posture from level: enforce at crew/fleet, advisory at solo/pair, open if unknown
enforce=0 level=""
_cfg="$(il_cfg_dir "$TARGET")/config.json"
if [ -f "$_cfg" ]; then
  level="$(sed -n 's/.*"level"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$_cfg" | head -1)"
  case "$level" in crew|fleet) enforce=1 ;; esac
fi

# --- extract a section body: lines between a '## Heading' and the next '## ' heading
_section() { awk -v h="$1" '
  /^## / { if (inq) inq=0; if ($0==h) inq=1; next }
  inq { print }
' "$2"; }

# acceptance criteria satisfied = >=1 checkbox bullet with real content (not the "..." placeholder)
crit_ok=0
crit="$(_section "## Acceptance criteria" "$FILE")"
if printf '%s\n' "$crit" | grep -qE '^[[:space:]]*- \[[ xX]\][[:space:]]+.+' \
   && printf '%s\n' "$crit" | grep -E '^[[:space:]]*- \[[ xX]\][[:space:]]+.+' \
        | grep -qvE '^[[:space:]]*- \[[ xX]\][[:space:]]+\.\.\.[[:space:]]*$'; then
  crit_ok=1
fi

# evidence satisfied = the evidence section has non-blank, non-placeholder content
ev_ok=0
ev="$(_section "## Verification evidence" "$FILE")"
if printf '%s\n' "$ev" | grep -vE '^[[:space:]]*$' | grep -qvE '^[[:space:]]*\(populated'; then
  ev_ok=1
fi

reasons=""
[ "$crit_ok" = 1 ] || reasons="${reasons}no real acceptance criteria; "
[ "$ev_ok" = 1 ]   || reasons="${reasons}no verification evidence captured; "

if [ -z "$reasons" ]; then
  echo "verify-gate: PASS"
  exit 0
fi
if [ "$enforce" = 1 ]; then
  echo "verify-gate: BLOCK — ${reasons}(level '${level}' enforces the verification contract)" >&2
  exit 3
fi
echo "verify-gate: ADVISORY — ${reasons}(level '${level:-unset}' is advisory)" >&2
exit 0
