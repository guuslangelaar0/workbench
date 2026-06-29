#!/usr/bin/env bash
# status-overview intent should route to /workbench:mc -> its dashboard signature appears
grep -qiE 'mission control' "$RUN_OUTPUT" 2>/dev/null && exit 0 || exit 1
