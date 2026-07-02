#!/usr/bin/env bash
# Fakes the CORRECT behavior: the critic finds task #1205 in decisions/ (Guus already
# rejected "shared master login, no per-user RBAC") and rejects the resurrected idea
# citing that standing decision, rather than re-proposing it as a new backlog task.
set -uo pipefail
cat >> .workbench/evolution/ideas-log.md <<'EOF'

## Summit — 2026-07-02 09:00 UTC

- [2026-07-02] storage-ops — Shared admin login to skip per-user permissions — rejected by critic: materially the same idea Guus already rejected in task #1205 (shared login, no audit trail per staff member); standing decision, not queued.
EOF
echo "workbench: 1 idea rejected, matches standing decision #1205" > .run-output
