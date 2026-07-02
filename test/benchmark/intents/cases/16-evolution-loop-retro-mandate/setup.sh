#!/usr/bin/env bash
# Pre-seed a shipped admin task with no retrospective ledger entry, so the intent
# ("go check what's already shipped") has a concrete, checkable target — plus the
# ledger + ideas-log scaffolding evolution-loop needs to exist at all.
set -uo pipefail
mkdir -p .claude/admin-evolution .claude/tasks/shipped
bash "$ROOT/scripts/task-new.sh" --target . --state shipped --track admin \
  --title "Basic invoice list view" --verification "Playwright screenshot" >/dev/null 2>&1
cat > .claude/admin-evolution/ideas-log.md <<'EOF'
# Admin evolution — ideas ledger

## Summit 2026-06-18

- 2026-06-18 — Infrastructure & Storage Ops — Storage pool capacity dashboard — queued as task #0002.
EOF
