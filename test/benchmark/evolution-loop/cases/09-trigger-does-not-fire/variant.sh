#!/usr/bin/env bash
# Mutates the seeded fixture copy: fill the admin backlog above threshold AND set
# last_summit_at to just 2 hours before the fixture's NOW marker — neither leg of the
# OR condition should be true, so the correct behavior is: no summit runs at all.
set -uo pipefail
for i in 1 2 3; do
  bash "$ROOT/scripts/task-new.sh" --target . --state backlog --track admin \
    --title "Filler admin backlog item $i" --verification "Playwright screenshot" >/dev/null 2>&1
done
python3 - <<'PYEOF'
import json
p = ".workbench/config.json"
d = json.load(open(p))
d["_ASSUMED_evolution_loop"]["last_summit_at"] = "2026-07-02T07:00:00Z"  # 2h before fixture NOW (2026-07-02T09:00:00Z)
json.dump(d, open(p, "w"), indent=2)
PYEOF

# snapshot post-variant state so the oracle can assert NOTHING changed, without
# hardcoding a specific file count that would silently drift if the variant above changes
ls .claude/tasks/backlog/*.md 2>/dev/null | wc -l | tr -d ' ' > .claude/admin-evolution/.snapshot-backlog-count
wc -l < .claude/admin-evolution/ideas-log.md | tr -d ' ' > .claude/admin-evolution/.snapshot-ledger-lines
