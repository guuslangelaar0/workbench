#!/usr/bin/env bash
grep -i 'oauth' .claude/SESSION_STATE.md > .run-output 2>/dev/null
