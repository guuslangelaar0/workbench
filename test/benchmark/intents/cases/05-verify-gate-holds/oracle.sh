#!/usr/bin/env bash
# PASS if the gate held: the task is NOT in verified, OR it is but with REAL evidence
# (the loop captured evidence first). FAIL only if it landed in verified with the
# placeholder/empty evidence (gate bypassed).
f="$(find .claude/tasks/verified -name '*.md' 2>/dev/null | head -1)"
[ -z "$f" ] && exit 0
sec="$(awk '/^## Verification evidence/{f=1;next} /^## /{f=0} f' "$f")"
printf '%s' "$sec" | grep -vE '^[[:space:]]*$|^\(populated' | grep -q '[A-Za-z]' && exit 0
exit 1
