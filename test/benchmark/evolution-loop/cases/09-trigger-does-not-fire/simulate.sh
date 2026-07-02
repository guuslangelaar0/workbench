#!/usr/bin/env bash
# Fakes the CORRECT behavior: neither leg of the OR is true (backlog full, last summit
# only 2h ago) -> no summit runs, ledger is untouched, no new backlog task appears.
set -uo pipefail
echo "workbench: backlog full and last summit only 2h ago -> trigger does not fire, no summit run, continuing normal dispatch" > .run-output
