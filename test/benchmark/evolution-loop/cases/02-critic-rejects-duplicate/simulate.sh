#!/usr/bin/env bash
# Fakes the CORRECT behavior: the critic recognizes "bulk-cancel refunds" duplicates
# the existing backlog task #1200 and rejects it (merged/duplicate), rather than
# synthesizing a second task file for the same idea. Ledger records the rejection.
set -uo pipefail
cat >> .workbench/evolution/ideas-log.md <<'EOF'

## Summit — 2026-07-02 09:00 UTC

- [2026-07-02] support-lead — Bulk-cancel refunds in the admin UI — rejected by critic: duplicate of existing backlog task #1200 (Add bulk refund cancellation UI), not queued.
EOF
echo "workbench: 1 idea rejected as duplicate of #1200, no new task created" > .run-output
