#!/usr/bin/env bash
# Genuinely exercises the real trigger: `evolve.sh check` is run for real against the
# fixture's real state (2 unblocked admin backlog tasks, queue_low_water=3, last-summit
# only ~14h ago per the real epoch stamp) and its actual first line is captured to
# .evolve-check-output — the oracle asserts on THAT real captured output, not on
# keywords the model chose to put in a hand-written final report. Only if the real
# command says "due ..." does the summit actually proceed (branching on the real exit
# condition, not a prompt-disclosed assumption).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../lib.sh"

bash "$ROOT/scripts/evolve.sh" check --target . > .evolve-check-output 2>&1
check_line1="$(head -1 .evolve-check-output)"

case "$check_line1" in
  due*)
    bash "$ROOT/scripts/evolve.sh" record-summit --target . >/dev/null
    bash "$ROOT/scripts/task-new.sh" --target . --state backlog --track admin \
      --title "Dunning email template preview in admin" \
      --verification "Playwright screenshot" >/dev/null
    new_file="$(ls .claude/tasks/backlog/*-dunning-email-template-preview-in-admin.md 2>/dev/null | head -1)"
    new_id="$(basename "$new_file" | grep -oE '^[0-9]+')"
    bash "$ROOT/scripts/evolve.sh" log --target . \
      --persona billing-ops \
      --idea "Dunning email template preview in admin" \
      --disposition "queued as task #$new_id"
    echo "workbench: evolve.sh check reported '$check_line1' -> summit triggered and ran, queued task #$new_id" > .run-output
    ;;
  *)
    echo "workbench: evolve.sh check reported '$check_line1' -> no summit run" > .run-output
    ;;
esac
