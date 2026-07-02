#!/usr/bin/env bash
# Mutates the seeded fixture copy: fill the admin backlog well above threshold (5
# unblocked tasks), and age last_summit_at in .workbench/config.json (and the ledger's
# most recent entry, textually) to 10 days ago — so backlog pressure is NOT the reason
# a summit should fire; only the 24h-elapsed leg should.
set -uo pipefail
for i in 1 2 3; do
  bash "$ROOT/scripts/task-new.sh" --target . --state backlog --track admin \
    --title "Filler admin backlog item $i" --verification "Playwright screenshot" >/dev/null 2>&1
done
python3 - <<'PYEOF'
import re, json
p = ".workbench/config.json"
d = json.load(open(p))
d["_ASSUMED_evolution_loop"]["last_summit_at"] = "2026-06-22T09:00:00Z"  # 10 days before fixture's implied "now"
json.dump(d, open(p, "w"), indent=2)
PYEOF
