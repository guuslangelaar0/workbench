#!/usr/bin/env bash
# Pre-seed a near-empty admin backlog + a stale last-summit marker, so the prompt's
# claim ("almost empty backlog, over a day since last summit") is grounded in real
# project state rather than the model having to take the user's word for it.
#
# ASSUMPTION: no config path for evolution-loop settings exists yet upstream — this
# mirrors the same _ASSUMED_evolution_loop shape used in test/benchmark/evolution-loop/
# fixture/project-a/.workbench/config.json. See that suite's cases/README.md.
set -uo pipefail
mkdir -p .claude/admin-evolution
cat > .claude/admin-evolution/ideas-log.md <<'EOF'
# Admin evolution — ideas ledger

## Summit 2026-06-25

- 2026-06-25 — Infrastructure & Storage Ops — Storage pool capacity dashboard — queued as task #0002.
EOF
echo "2026-07-02T09:00:00Z" > .claude/admin-evolution/NOW-for-eval-fixture-only

python3 - <<'PYEOF' 2>/dev/null || true
import json, os
p = ".workbench/config.json"
if os.path.exists(p):
    d = json.load(open(p))
    d["_ASSUMED_evolution_loop"] = {
        "track": "admin",
        "summit_trigger": {"backlog_below": 3, "max_hours_since_last_summit": 24},
        "personas": {
            "generators": ["visionary-product-strategist", "customer-support-lead",
                            "infra-storage-ops", "billing-finance-ops"],
            "critic": "completeness-trust-critic"
        },
        "ideas_ledger_path": ".claude/admin-evolution/ideas-log.md",
        "last_summit_at": "2026-06-25T09:00:00Z"
    }
    json.dump(d, open(p, "w"), indent=2)
PYEOF
