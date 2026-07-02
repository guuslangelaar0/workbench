#!/usr/bin/env bash
# Genuinely EXERCISES the real evolve.sh subcommands rather than hand-writing the
# expected end-state: `evolve.sh check` confirms the summit is actually due (real
# trigger logic against the real fixture), `evolve.sh retro-candidates` picks the real
# retrospective target, `task-new.sh` scaffolds each synthesized task (real ID
# allocation + real template), `evolve.sh log` appends every persona's disposition for
# real (not just the synthesized one — a full summit's worth: two OTHER generators'
# ideas deferred, plus the critic's retro finding), and `evolve.sh record-summit`
# stamps the summit heading for real. The only stand-in is the actual PROSE content of
# what each persona proposes/decides (the part evolve.sh has no opinion on and a real
# persona-panel LLM would author) — el_fill_task in lib.sh isolates exactly that gap.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../lib.sh"

# 1. Confirm the summit is actually due via the real trigger — not assumed.
due_line="$(bash "$ROOT/scripts/evolve.sh" check --target . | head -1)"
case "$due_line" in
  due*) : ;;
  *) echo "simulate.sh: evolve.sh check says '$due_line', not due — aborting simulated summit" >&2; exit 1 ;;
esac

# 2. Real retrospective pick for this cycle (oldest unaudited verified/shipped admin task).
retro_id="$(bash "$ROOT/scripts/evolve.sh" retro-candidates --target . --track admin | head -1)"

# 3. Stamp the summit heading for real FIRST (real record-summit, real UTC timestamp) —
#    every persona disposition below must be logged as belonging to THIS summit, so the
#    heading has to exist before any `evolve.sh log` call appends under it.
bash "$ROOT/scripts/evolve.sh" record-summit --target . >/dev/null

# 4. Generator personas raise ideas. Two are judged not worth a NEW task this round
#    (both deferred) — logged via the real `evolve.sh log`, exercising the
#    ledger-append path for a whole summit, not just the single synthesized idea.
bash "$ROOT/scripts/evolve.sh" log --target . \
  --persona product-visionary \
  --idea "Bulk-tag admin backlog items by revenue impact" \
  --disposition "deferred: overlaps planned billing-ops work this cycle, revisit next summit"
bash "$ROOT/scripts/evolve.sh" log --target . \
  --persona storage-ops \
  --idea "Per-region pool alert thresholds" \
  --disposition "deferred: no incident pressure yet, not this cycle"

# 5. The idea that DOES survive critic review becomes a real task via task-new.sh
#    (real _next-id allocation, real template render) — content is then filled in,
#    the one part evolve.sh itself has no mechanism for.
bash "$ROOT/scripts/task-new.sh" --target . --state backlog --track admin \
  --title "Refund cancellation audit log export" \
  --verification "Playwright screenshot of the export flow" >/dev/null

new_file="$(ls .claude/tasks/backlog/*-refund-cancellation-audit-log-export.md 2>/dev/null | head -1)"
new_id="$(basename "$new_file" | grep -oE '^[0-9]+')"

el_fill_task "$new_file" \
  "Refunds that get cancelled leave no visible trail for support or finance to audit later — when a customer disputes a cancelled refund, there is currently no exportable record of who cancelled it, when, and why." \
  "- [ ] Every refund cancellation is logged with actor, timestamp, and reason
- [ ] The log is exportable as CSV from the admin billing view" \
  "- Happy path: an admin cancels a refund, the action appears in the exportable log
- Edge / negative: export with zero cancellations in range still produces a valid empty CSV"

bash "$ROOT/scripts/evolve.sh" log --target . \
  --persona billing-ops \
  --idea "Refund cancellation audit log export" \
  --disposition "queued as task #$new_id"

# 6. The critic also logs the real retrospective finding for whichever task
#    evolve.sh retro-candidates actually picked (traceable to that real output, not
#    a hardcoded id).
if [ -n "$retro_id" ]; then
  bash "$ROOT/scripts/evolve.sh" log --target . \
    --persona critic \
    --idea "retrospective audit of task #$retro_id" \
    --disposition "verified but checkbox-done — no search, no date-range filter, no export; no expansion queued this cycle, flagged for next retro slot"
fi

echo "workbench: summit synthesized task #$new_id (billing-ops), retro-audited #$retro_id (critic), 2 other ideas deferred, updated ideas ledger" > .run-output
