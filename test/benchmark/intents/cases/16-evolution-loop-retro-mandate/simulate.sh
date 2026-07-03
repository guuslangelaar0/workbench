#!/usr/bin/env bash
# Use the real `evolve.sh log --audit-of` so the structural [audit:#0001] marker is
# written (not a free-text entry), matching what a live model using the evolve skill
# would produce. The oracle checks both the idea text AND the structural marker.
set -uo pipefail
bash "$ROOT/scripts/evolve.sh" record-summit --target . >/dev/null 2>&1 || true
bash "$ROOT/scripts/evolve.sh" log --target . \
  --audit-of 0001 \
  --persona critic \
  --idea "retrospective audit of task #0001" \
  --disposition "verified but checkbox-done, no search/filter/export — queued follow-up"
echo "workbench: retrospective audit ran against shipped task #0001" > .run-output
