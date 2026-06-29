#!/usr/bin/env bash
# the "features are suggested, never auto-built" rule -> a suggestion (or decision), not an
# in-development build task.
{ ls .workbench/suggestions/*.suggest >/dev/null 2>&1 && grep -riqE 'dark|mode|settings' .workbench/suggestions/ ; } && exit 0
grep -rliE 'dark mode' .claude/tasks/decisions/ 2>/dev/null | grep -q . && exit 0
exit 1
