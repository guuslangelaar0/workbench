#!/usr/bin/env bash
# Pre-seed a near-empty admin backlog + a stale last-summit marker, so the prompt's
# claim ("almost empty backlog, over a day since last summit") is grounded in real
# project state rather than the model having to take the user's word for it.
#
# Uses the REAL evolution-loop scaffolding (scripts/evolve.sh init --preset admin-example,
# templates/schemas/personas.schema.json) — roster + ledger live under
# .workbench/evolution/, not .workbench/config.json.
set -uo pipefail
bash "$ROOT/scripts/evolve.sh" init --target . --preset admin-example >/dev/null 2>&1

cat > .workbench/evolution/ideas-log.md <<'EOF'
# Ideas ledger — evolution summits

Created: 2026-06-01

## Summit — 2026-06-25 09:00 UTC

- [2026-06-25] storage-ops — Storage pool capacity dashboard — queued as task #0002.
EOF
echo "2026-07-02T09:00:00Z" > .workbench/evolution/NOW-for-eval-fixture-only

# last summit 7+ days ago -> the 24h cadence leg of the trigger is true
echo 1782118800 > .workbench/evolution/last-summit
