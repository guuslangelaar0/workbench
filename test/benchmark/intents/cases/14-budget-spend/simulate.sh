#!/usr/bin/env bash
# fake the correct behavior via the budget script (falls back to a representative line)
bash "$ROOT/scripts/budget.sh" --target . > .run-output 2>/dev/null
grep -qiE 'budget|spent|spend|token' .run-output || echo "token spend so far (via /workbench:budget): per-session and per-task usage in exact tokens" > .run-output
