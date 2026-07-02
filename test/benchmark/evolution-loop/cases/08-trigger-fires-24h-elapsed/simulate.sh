#!/usr/bin/env bash
# Fakes the CORRECT behavior: even though backlog is well-stocked (post-variant.sh),
# 10 days since last_summit_at exceeds the 24h ceiling -> the trigger fires anyway, and
# a summit runs (this time likely a retrospective-heavy one, per the spec's "so the
# retrospective mandate doesn't get starved during quiet periods").
set -uo pipefail
cat >> .workbench/evolution/ideas-log.md <<'EOF'

## Summit — 2026-07-02 09:00 UTC

- [2026-07-02] critic — retrospective audit of task #1203: verified but checkbox-done, no search/filter/export — queued follow-up as task #1210. (trigger: 24h+ elapsed since last summit, backlog was already full)
EOF
echo "workbench: backlog was full, but 10 days since last summit exceeds the 24h ceiling -> summit triggered" > .run-output
