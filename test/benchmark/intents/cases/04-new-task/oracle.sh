#!/usr/bin/env bash
grep -rliE 'rate.?limit' .claude/tasks/ 2>/dev/null | grep -q . && exit 0 || exit 1
