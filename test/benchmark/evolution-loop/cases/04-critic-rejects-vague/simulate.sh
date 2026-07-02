#!/usr/bin/env bash
# Genuinely exercises the real evolve.sh subcommands: `evolve.sh check` confirms the
# summit is due, `evolve.sh record-summit` stamps a real heading, `task-new.sh`
# scaffolds the ONE idea that survives critic review (real _next-id + real template),
# and `evolve.sh log` appends BOTH the vague idea's rejection and the concrete idea's
# queue disposition for real. The vague idea deliberately gets NO task-new.sh call at
# all — that omission (not a hand-written "expected" ledger line) is the actual
# behavior under test: a critic that rubber-stamps everything would scaffold a task
# for it too.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../lib.sh"

due_line="$(bash "$ROOT/scripts/evolve.sh" check --target . | head -1)"
case "$due_line" in
  due*) : ;;
  *) echo "simulate.sh: evolve.sh check says '$due_line', not due — aborting simulated summit" >&2; exit 1 ;;
esac

bash "$ROOT/scripts/evolve.sh" record-summit --target . >/dev/null

# The vague idea: no task-new.sh call, critic kills it for lacking checkable criteria.
bash "$ROOT/scripts/evolve.sh" log --target . \
  --persona product-visionary \
  --idea "Make admin better and more powerful in general" \
  --disposition "rejected by critic: not actionable, no checkable acceptance criteria possible, too vague to scope"

# The concrete companion idea DOES survive — real task-new.sh scaffold, content filled.
bash "$ROOT/scripts/task-new.sh" --target . --state backlog --track admin \
  --title "Add CSV export to the invoice list view" \
  --verification "Playwright screenshot of the export button + downloaded file" >/dev/null

new_file="$(ls .claude/tasks/backlog/*-add-csv-export-to-the-invoice-list-view.md 2>/dev/null | head -1)"
new_id="$(basename "$new_file" | grep -oE '^[0-9]+')"

el_fill_task "$new_file" \
  "The invoice list view (#1203) has no export, so finance has to screenshot or manually retype rows when reconciling a customer's invoice history." \
  "- [ ] An 'Export CSV' button appears on the invoice list view
- [ ] Clicking it downloads a CSV with all visible rows" \
  "- Happy path: clicking Export CSV downloads a file with all visible invoice rows
- Edge / negative: an empty invoice list still exports a valid header-only CSV"

bash "$ROOT/scripts/evolve.sh" log --target . \
  --persona support-lead \
  --idea "Add CSV export to the invoice list view" \
  --disposition "queued as task #$new_id"

echo "workbench: 1 vague idea rejected, task #$new_id queued" > .run-output
