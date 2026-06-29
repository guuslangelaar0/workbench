#!/usr/bin/env bash
ls .claude/epics/*.md >/dev/null 2>&1 && grep -rliE 'billing|subscription' .claude/epics/ >/dev/null 2>&1 && exit 0 || exit 1
