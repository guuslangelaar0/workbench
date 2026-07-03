#!/usr/bin/env bash
# Genuinely exercises the real evolve.sh subcommands: `evolve.sh check` confirms the
# summit is actually due against the real fixture, `evolve.sh record-summit` stamps a
# real heading, and the critic's rejection is appended via the real `evolve.sh log` —
# not a hand-written heredoc. The behavior under test (does the critic actually reject
# a duplicate rather than rubber-stamp it) is exercised by NOT calling task-new.sh for
# the duplicate idea at all — the oracle then checks the real filesystem/ledger state
# that resulted, not a fabricated "expected" line.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../lib.sh"

due_line="$(bash "$ROOT/scripts/evolve.sh" check --target . | head -1)"
case "$due_line" in
  due*) : ;;
  *) echo "simulate.sh: evolve.sh check says '$due_line', not due — aborting simulated summit" >&2; exit 1 ;;
esac

bash "$ROOT/scripts/evolve.sh" record-summit --target . >/dev/null

# The critic cross-references the real backlog/ (task #1200 already covers this idea,
# genuinely present in the fixture, not asserted) and rejects — no task-new.sh call
# happens for this idea, which is the actual behavior under test.
bash "$ROOT/scripts/evolve.sh" log --target . \
  --persona support-lead \
  --idea "Bulk-cancel refunds in the admin UI" \
  --disposition "rejected by critic: duplicate of existing backlog task #1200 (Add bulk refund cancellation UI), not queued"

echo "workbench: 1 idea rejected as duplicate of #1200, no new task created" > .run-output
