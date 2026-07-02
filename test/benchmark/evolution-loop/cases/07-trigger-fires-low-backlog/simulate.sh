#!/usr/bin/env bash
# Fakes the CORRECT behavior: backlog (2) is below threshold (3) -> the trigger fires
# even though elapsed time is small, and a summit actually runs (produces a new task +
# ledger entry). This is the "backlog pressure" half of the OR condition.
set -uo pipefail
bash "$ROOT/scripts/task-new.sh" --target . --state backlog --track admin \
  --title "Dunning email template preview in admin" \
  --verification "Playwright screenshot" >/dev/null 2>&1
cat >> .workbench/evolution/ideas-log.md <<'EOF'

## Summit — 2026-07-02 09:00 UTC

- [2026-07-02] billing-ops — Dunning email template preview in admin — queued as task #1206. (trigger: backlog below threshold)
EOF
echo "workbench: backlog (2) below threshold (3) -> summit triggered and ran" > .run-output
