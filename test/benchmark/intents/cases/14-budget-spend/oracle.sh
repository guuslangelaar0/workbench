#!/usr/bin/env bash
# spend/cost intent should route to /workbench:budget -> spend/token signature appears
grep -qiE 'budget|spent|spend|token' "$RUN_OUTPUT" 2>/dev/null && exit 0 || exit 1
