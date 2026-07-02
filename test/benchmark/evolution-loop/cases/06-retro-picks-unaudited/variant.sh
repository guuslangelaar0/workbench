#!/usr/bin/env bash
# Mutates the seeded fixture copy: #1203 gets its retro entry too (so BOTH pre-existing
# verified/shipped tasks are now covered), and a NEW, newer verified admin task (#1207,
# with no retro entry) is added. The correct pick this round is #1207 — proving the
# mechanism actually greps the ledger and generalizes, rather than a hardcoded "#1203".
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../lib.sh"

# Real structural audit marker (evolve.sh log --audit-of), not a hand-written
# heredoc — matches how the base fixture's #1204 entry is now seeded too, so
# _audited_ids recognizes this as genuine coverage rather than free text.
bash "$ROOT/scripts/evolve.sh" log --target . --audit-of 1203 \
  --persona critic \
  --idea "retrospective audit of task #1203" \
  --disposition "verified but checkbox-done, no search/filter/export — queued follow-up as task #1210 (fixture-only entry, no actual #1210 file needed for this variant)" >/dev/null

# bump _next-id past #1206 (reserved by other cases' synthesis output) so this
# fixture-only verified task lands at the ID the case is written around: #1207
echo "1207" > .claude/tasks/_next-id
bash "$ROOT/scripts/task-new.sh" --target . --state verified --track admin \
  --title "Refund reason codes on the refund detail page" \
  --verification "Playwright screenshot of the refund detail page" >/dev/null 2>&1
OUT=".claude/tasks/verified/1207-refund-reason-codes-on-the-refund-detail-page.md"
python3 - "$OUT" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace(
    "(one paragraph: the user-facing reason this exists)",
    "Refund detail pages showed no reason code, so support had to open the "
    "underlying Stripe dashboard to see why a refund was issued."
)
open(p, "w").write(s)
PYEOF
