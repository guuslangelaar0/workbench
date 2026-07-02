#!/usr/bin/env bash
# Fakes the CORRECT synthesis behavior: a new, critic-approved idea becomes a real task
# file via the project's own task-new.sh (the exact mechanism the spec requires — "no new
# file format, no new directory"), plus a ledger entry recording its disposition.
set -uo pipefail
bash "$ROOT/scripts/task-new.sh" --target . --state backlog --track admin \
  --title "Refund cancellation audit log export" \
  --verification "Playwright screenshot of the export flow" >/dev/null 2>&1

OUT=".claude/tasks/backlog/1206-refund-cancellation-audit-log-export.md"
# task-new.sh only scaffolds the skeleton with placeholder prose — synthesis is not
# "well-formed" until the placeholders are actually replaced with real content. A real
# summit's synthesis stage does this; simulate it here so the oracle has something
# genuinely well-formed to check (this is the behavior under test, not incidental).
python3 - "$OUT" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace(
    "(one paragraph: the user-facing reason this exists)",
    "Refunds that get cancelled leave no visible trail for support or finance to "
    "audit later — when a customer disputes a cancelled refund, there is currently "
    "no exportable record of who cancelled it, when, and why."
)
s = s.replace(
    "<!-- the checkable definition of done, written BEFORE dispatch. Replace the placeholder. -->\n- [ ] ...",
    "<!-- the checkable definition of done, written BEFORE dispatch. Replace the placeholder. -->\n"
    "- [ ] Every refund cancellation is logged with actor, timestamp, and reason\n"
    "- [ ] The log is exportable as CSV from the admin billing view"
)
s = s.replace(
    "- Happy path: ...\n- Edge / negative: ...",
    "- Happy path: an admin cancels a refund, the action appears in the exportable log\n"
    "- Edge / negative: export with zero cancellations in range still produces a valid empty CSV"
)
open(p, "w").write(s)
PYEOF

cat >> .claude/admin-evolution/ideas-log.md <<'EOF'

## Summit 2026-07-02

- 2026-07-02 — Billing & Finance Ops — Refund cancellation audit log export
  — queued as task #1206.
EOF
echo "workbench: summit synthesized 1 task, updated ideas ledger" > .run-output
