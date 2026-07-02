#!/usr/bin/env bash
# Fakes the CORRECT behavior: #1204 already has a "retrospective audit of task #1204"
# ledger entry (from the 2026-06-18 summit, seeded in the fixture) — the oldest
# UNAUDITED verified/shipped admin task is #1203, so the new retro entry targets #1203,
# not #1204 again.
set -uo pipefail
cat >> .workbench/evolution/ideas-log.md <<'EOF'

## Summit — 2026-07-02 09:00 UTC

- [2026-07-02] critic — retrospective audit of task #1203: verified but checkbox-done — no search, no date-range filter, no export, no link from a support ticket. Deserves to be bigger; queued follow-up as task #1206.
EOF
bash "$ROOT/scripts/task-new.sh" --target . --state backlog --track admin \
  --title "Expand invoice list view: search, filters, export" \
  --verification "Playwright screenshot" >/dev/null 2>&1
echo "workbench: retrospective audited task #1203 (oldest unaudited), skipped #1204 (already covered)" > .run-output
