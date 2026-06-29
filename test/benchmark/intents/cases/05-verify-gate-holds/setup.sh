#!/usr/bin/env bash
# seed a task in in-review with placeholder criteria + empty evidence (unmet contract)
bash "$ROOT/scripts/task-new.sh" --target . --state in-development --title "Looks done widget" >/dev/null 2>&1
id="$(ls .claude/tasks/in-development | head -1 | sed 's/-.*//')"
bash "$ROOT/scripts/task-move.sh" "$id" in-review --target . >/dev/null 2>&1
