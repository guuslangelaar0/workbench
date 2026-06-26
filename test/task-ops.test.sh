#!/usr/bin/env bash
# Behavioral tests for task-new.sh (ID allocation, slug, fields, _next-id bump)
# and task-move.sh (mv + git-mv lifecycle transitions, Status update).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # workbench
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail=0
chk() { if eval "$2"; then echo "ok: $1"; else echo "FAIL: $1" >&2; fail=1; fi; }

# scaffold a minimal project (gives us .claude/tasks/ + _next-id at 0001)
bash "$HERE/scripts/init.sh" --name "Acme" --mission "Test." --target "$TMP" --profile minimal >/dev/null 2>&1

chk "next-id starts 0001" "[ \"\$(cat '$TMP/.claude/tasks/_next-id')\" = 0001 ]"

# create a task with all fields; title has '&' and mixed case to exercise slug + render-escaping
bash "$HERE/scripts/task-new.sh" --title "Implement Folder Sharing & Links" \
  --track sharing --repos "web,server" --estimate "~1 day" --target "$TMP" >/dev/null

T1="$TMP/.claude/tasks/backlog/0001-implement-folder-sharing-links.md"
chk "task file created at expected slug" "[ -f '$T1' ]"
chk "title rendered (with &)"            "grep -q 'Implement Folder Sharing & Links' '$T1'"
chk "status is backlog"                  "grep -q '^\\*\\*Status:\\*\\* backlog' '$T1'"
chk "track field rendered"               "grep -q '^\\*\\*Track:\\*\\* sharing' '$T1'"
chk "repos field rendered"               "grep -q '^\\*\\*Repo(s):\\*\\* web,server' '$T1'"
chk "estimate field rendered"            "grep -q '^\\*\\*Estimate:\\*\\* ~1 day' '$T1'"
chk "created field rendered"             "grep -q '^\\*\\*Created:\\*\\* 2' '$T1'"
chk "no leftover render tokens"          "! grep -q '{{' '$T1'"
chk "_next-id bumped to 0002"            "[ \"\$(cat '$TMP/.claude/tasks/_next-id')\" = 0002 ]"

# a second task increments again (defaults for optional fields)
bash "$HERE/scripts/task-new.sh" --title "Second Task" --target "$TMP" >/dev/null
chk "second task id 0002"   "[ -f '$TMP/.claude/tasks/backlog/0002-second-task.md' ]"
chk "_next-id now 0003"     "[ \"\$(cat '$TMP/.claude/tasks/_next-id')\" = 0003 ]"

# B1 regression: a title containing a {{KEY}} token must render literally (no token-bleed)
bash "$HERE/scripts/task-new.sh" --title "Add {{ESTIMATE}} rollup to mc" --target "$TMP" >/dev/null
BL="$TMP/.claude/tasks/backlog/0003-add-estimate-rollup-to-mc.md"
chk "title with {{token}} renders literally"   "grep -q 'Add {{ESTIMATE}} rollup to mc' '$BL'"
chk "real Estimate field unaffected by bleed"   "grep -q '^\\*\\*Estimate:\\*\\* (unestimated)' '$BL'"

# task-move.sh in a NON-git target → mv fallback + Status rewrite
bash "$HERE/scripts/task-move.sh" 0001 in-development --target "$TMP" >/dev/null
chk "0001 left backlog"               "[ ! -f '$T1' ]"
M1="$TMP/.claude/tasks/in-development/0001-implement-folder-sharing-links.md"
chk "0001 now in in-development"      "[ -f '$M1' ]"
chk "status rewritten to in-development" "grep -q '^\\*\\*Status:\\*\\* in-development' '$M1'"

# move again to verified
bash "$HERE/scripts/task-move.sh" 0001 verified --target "$TMP" >/dev/null
chk "0001 now in verified"           "[ -f '$TMP/.claude/tasks/verified/0001-implement-folder-sharing-links.md' ]"

# S2: a hand-authored task with no **Status:** line gets one injected on move
printf '# 0042 — Hand authored\n\n## Why\nx\n' > "$TMP/.claude/tasks/backlog/0042-hand-authored.md"
bash "$HERE/scripts/task-move.sh" 0042 in-development --target "$TMP" >/dev/null 2>&1
HM="$TMP/.claude/tasks/in-development/0042-hand-authored.md"
chk "0042 moved despite missing status"  "[ -f '$HM' ]"
chk "missing Status line injected"        "grep -q '^\\*\\*Status:\\*\\* in-development' '$HM'"

# task-move.sh in a GIT target → git mv path (rename tracked)
( cd "$TMP" && git init -q && git add -A && git -c user.email=t@t -c user.name=t commit -qm init ) >/dev/null 2>&1
bash "$HERE/scripts/task-move.sh" 0002 in-review --target "$TMP" >/dev/null
chk "0002 git-moved to in-review"    "[ -f '$TMP/.claude/tasks/in-review/0002-second-task.md' ]"
chk "git sees the move"              "git -C '$TMP' status --porcelain | grep -q 'in-review/0002-second-task.md'"

# unknown id is an error
chk "unknown id exits non-zero"      "! bash '$HERE/scripts/task-move.sh' 9999 verified --target '$TMP' >/dev/null 2>&1"

[ "$fail" = 0 ] && echo "PASS: task-ops" || { echo "task-ops test failed"; exit 1; }
