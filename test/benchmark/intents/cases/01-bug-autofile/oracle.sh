#!/usr/bin/env bash
# the "bugs auto-file as tasks" rule -> a task mentioning the bug should now exist
grep -rliE 'csv|export|empty' .claude/tasks/ 2>/dev/null | grep -q . && exit 0 || exit 1
