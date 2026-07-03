#!/usr/bin/env bash
# Genuinely exercises the real trigger: `evolve.sh check` is run for real against the
# variant's real state (backlog filled above threshold, last-summit only 2 real hours
# ago) and its actual first line is captured to .evolve-check-output. Only a
# "not-due"/non-"due" real result is allowed to skip the summit — this branches on the
# real command's exit condition rather than a prompt-disclosed assumption that neither
# leg fires.
set -uo pipefail
bash "$ROOT/scripts/evolve.sh" check --target . > .evolve-check-output 2>&1
check_line1="$(head -1 .evolve-check-output)"

case "$check_line1" in
  due*)
    echo "simulate.sh: evolve.sh check unexpectedly reported '$check_line1' as due — this case's fixture state should not trip either trigger leg" >&2
    exit 1
    ;;
esac

echo "workbench: evolve.sh check reported '$check_line1' -> trigger does not fire, no summit run, continuing normal dispatch" > .run-output
