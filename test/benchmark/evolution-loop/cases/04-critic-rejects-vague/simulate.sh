#!/usr/bin/env bash
# Fakes the CORRECT behavior: the critic kills the unscoped "make admin better and
# more powerful in general" idea (fails the "is this actually finished/verified... does
# it fit" bar — an idea with no checkable acceptance criteria can't be), while a
# concrete companion idea from the same summit DOES get synthesized. This is the key
# discriminator vs. a critic that rubber-stamps everything: SOME ideas should pass.
set -uo pipefail
bash "$ROOT/scripts/task-new.sh" --target . --state backlog --track admin \
  --title "Add CSV export to the invoice list view" \
  --verification "Playwright screenshot of the export button + downloaded file" >/dev/null 2>&1
OUT=".claude/tasks/backlog/1206-add-csv-export-to-the-invoice-list-view.md"
python3 - "$OUT" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace(
    "(one paragraph: the user-facing reason this exists)",
    "The invoice list view (#1203) has no export, so finance has to screenshot or "
    "manually retype rows when reconciling a customer's invoice history."
)
s = s.replace(
    "<!-- the checkable definition of done, written BEFORE dispatch. Replace the placeholder. -->\n- [ ] ...",
    "<!-- the checkable definition of done, written BEFORE dispatch. Replace the placeholder. -->\n"
    "- [ ] An 'Export CSV' button appears on the invoice list view\n"
    "- [ ] Clicking it downloads a CSV with all visible rows"
)
open(p, "w").write(s)
PYEOF

cat >> .claude/admin-evolution/ideas-log.md <<'EOF'

## Summit 2026-07-02

- 2026-07-02 — Visionary / Product Strategist — Make admin better and more
  powerful in general — rejected by critic: not actionable, no checkable
  acceptance criteria possible, too vague to scope.
- 2026-07-02 — Customer Support Lead — Add CSV export to the invoice list
  view — queued as task #1206.
EOF
echo "workbench: 1 vague idea rejected, 1 concrete idea queued" > .run-output
