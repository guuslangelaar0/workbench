#!/usr/bin/env bash
# at/over cap the loop should recognize it and drain/verify, not blindly open new work
grep -qiE 'cap|in.?review|drain|verif' "$RUN_OUTPUT" 2>/dev/null && exit 0 || exit 1
