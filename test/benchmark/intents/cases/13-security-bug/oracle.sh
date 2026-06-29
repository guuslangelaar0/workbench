#!/usr/bin/env bash
# correct behavior: a security bug is captured as a tracked task (not just discussed)
grep -rliE 'password|plaintext|secret|security' .claude/tasks/ 2>/dev/null | grep -q . && exit 0 || exit 1
