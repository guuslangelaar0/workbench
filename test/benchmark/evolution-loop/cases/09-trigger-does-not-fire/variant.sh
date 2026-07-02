#!/usr/bin/env bash
# Mutates the seeded fixture copy: fill the admin backlog above threshold AND set
# .workbench/evolution/last-summit (the real stamp file evolve.sh record-summit/check
# reads, epoch seconds) to just 2 hours before the fixture's NOW marker — neither leg
# of the OR condition should be true, so the correct behavior is: no summit runs at all.
set -uo pipefail
for i in 1 2 3; do
  bash "$ROOT/scripts/task-new.sh" --target . --state backlog --track admin \
    --title "Filler admin backlog item $i" --verification "Playwright screenshot" >/dev/null 2>&1
done
# 2026-07-02T07:00:00Z, 2h before fixture NOW (2026-07-02T09:00:00Z)
echo 1782975600 > .workbench/evolution/last-summit

# snapshot post-variant state so the oracle can assert NOTHING changed — a genuine
# content checksum (not just file/line COUNTS, which a mutation that changes content
# while preserving counts would slip past). sha256 the full byte content of the ledger
# and of every backlog task file (name + content, so a rename or a content edit that
# keeps the same byte count both still show up as a diff).
sha256sum .workbench/evolution/ideas-log.md 2>/dev/null | awk '{print $1}' > .workbench/evolution/.snapshot-ledger-sha256
{ for f in .claude/tasks/backlog/*.md; do [ -f "$f" ] || continue; sha256sum "$f"; done; } \
  | sort -k2 > .workbench/evolution/.snapshot-backlog-sha256
cp .workbench/evolution/ideas-log.md .workbench/evolution/.snapshot-ledger-content
