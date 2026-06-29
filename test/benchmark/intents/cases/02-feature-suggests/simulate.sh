#!/usr/bin/env bash
bash "$ROOT/scripts/suggest.sh" add --key feature-dark-mode --severity recommend \
  --title "Add a dark mode toggle to settings" --why "user idea, not urgent" \
  --how "scope it as a task when prioritized" --source manual --target . >/dev/null 2>&1
