#!/usr/bin/env bash
# Pre-seed a shipped admin task with no retrospective ledger entry, so the intent
# ("go check what's already shipped") has a concrete, checkable target — plus the
# REAL evolution-loop scaffolding (scripts/evolve.sh init) so the roster + ledger
# exist under .workbench/evolution/ before the prompt runs.
set -uo pipefail
bash "$ROOT/scripts/evolve.sh" init --target . --preset admin-example >/dev/null 2>&1
mkdir -p .claude/tasks/shipped
bash "$ROOT/scripts/task-new.sh" --target . --state shipped --track admin \
  --title "Basic invoice list view" --verification "Playwright screenshot" >/dev/null 2>&1
cat > .workbench/evolution/ideas-log.md <<'EOF'
# Ideas ledger — evolution summits

Created: 2026-06-01

## Summit — 2026-06-18 09:00 UTC

- [2026-06-18] storage-ops — Storage pool capacity dashboard — queued as task #0002.
EOF
