#!/usr/bin/env bash
for i in $(seq 1 10); do printf '# %04d — queued\n**Status:** in-review\n' "$i" > ".claude/tasks/in-review/$(printf %04d "$i")-q.md"; done
