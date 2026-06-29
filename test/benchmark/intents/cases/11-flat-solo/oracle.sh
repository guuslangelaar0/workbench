#!/usr/bin/env bash
# solo decomposition is flat: no epic, but the work IS captured as backlog tasks
ls .claude/epics/*.md >/dev/null 2>&1 && exit 1
ls .claude/tasks/backlog/*.md >/dev/null 2>&1 && exit 0 || exit 1
