#!/usr/bin/env bash
ls .claude/tasks/decisions/*.md >/dev/null 2>&1 && exit 0 || exit 1
