#!/usr/bin/env bash
bash "$ROOT/scripts/task-new.sh" --target . --state backlog --track admin \
  --title "Evolution-loop synthesized idea" --verification "Playwright screenshot" >/dev/null 2>&1
printf '\n## Summit — 2026-07-02 09:00 UTC\n\n- [2026-07-02] critic — summit ran: backlog low + 24h+ elapsed\n' >> .workbench/evolution/ideas-log.md
echo "workbench: evolution-loop summit triggered (backlog low, >24h since last), synthesized 1 task" > .run-output
