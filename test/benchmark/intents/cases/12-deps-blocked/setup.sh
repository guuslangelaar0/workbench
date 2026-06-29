#!/usr/bin/env bash
# a blocker task + a checkout task that is Blocked-by it (still unfinished)
bash "$ROOT/scripts/task-new.sh" --target . --state backlog --title "Payment gateway integration" >/dev/null 2>&1
bid="$(ls .claude/tasks/backlog | head -1 | sed 's/-.*//')"
bash "$ROOT/scripts/task-new.sh" --target . --state backlog --title "Checkout flow" --blocked-by "$bid" >/dev/null 2>&1
