#!/usr/bin/env bash
# Behavioral test for mc.sh: runs the dashboard in a scaffolded project and
# asserts it surfaces the project name, lifecycle states, and a task by id.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # workbench
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail=0
chk() { if eval "$2"; then echo "ok: $1"; else echo "FAIL: $1" >&2; fail=1; fi; }

bash "$HERE/scripts/init.sh" --name "Acme" --mission "Test." --target "$TMP" --profile full --level fleet >/dev/null 2>&1
bash "$HERE/scripts/task-new.sh" --title "Dash Task" --estimate "~2h" --target "$TMP" >/dev/null
bash "$HERE/scripts/task-move.sh" 0001 in-review --target "$TMP" >/dev/null
JOB_OUT="$(bash "$HERE/scripts/job.sh" start codex-engineer 0001 --target "$TMP" --owner codex --runtime-mode background --summary 'Codex is editing files.')"
JOB_ID="$(printf '%s\n' "$JOB_OUT" | sed -n 's/^job: started //p' | awk '{print $1}')"
DONE_OUT="$(bash "$HERE/scripts/job.sh" start codex-engineer 0099 --target "$TMP" --owner codex --runtime-mode background --summary 'Already verified.')"
DONE_ID="$(printf '%s\n' "$DONE_OUT" | sed -n 's/^job: started //p' | awk '{print $1}')"
bash "$HERE/scripts/job.sh" update "$DONE_ID" --target "$TMP" --status verified --summary 'Verified by Workbench.' >/dev/null

out="$(cd "$TMP" && bash "$HERE/scripts/mc.sh" --no-prod --no-build 2>/dev/null)"

chk "prints project name"     "printf '%s' \"\$out\" | grep -q 'Acme'"
chk "shows backlog row"       "printf '%s' \"\$out\" | grep -q 'backlog'"
chk "shows in-review row"     "printf '%s' \"\$out\" | grep -q 'in-review'"
chk "lists the task id 0001"  "printf '%s' \"\$out\" | grep -q '0001'"
chk "shows in-review cap"     "printf '%s' \"\$out\" | grep -qi 'cap'"
chk "shows Jobs section"      "printf '%s' \"\$out\" | grep -q 'Jobs'"
chk "shows active codex job"  "printf '%s' \"\$out\" | grep -q \"$JOB_ID\" && printf '%s' \"\$out\" | grep -q 'Codex is editing files.'"
chk "hides terminal codex job" "! printf '%s' \"\$out\" | grep -q \"$DONE_ID\""
chk "exits 0 cleanly"         "(cd '$TMP' && bash '$HERE/scripts/mc.sh' --no-prod --no-build >/dev/null 2>&1)"

# Regression: root-detection guard must require BOTH .claude/tasks/ AND
# .workbench/config.json, and must stop walking up at $HOME -- otherwise a
# subdirectory of $HOME with no real project either errors confusingly or
# walks past HOME and renders a dashboard against an unrelated project.
FAKE_HOME="$(mktemp -d)"
mkdir -p "$FAKE_HOME/project/.claude/tasks" "$FAKE_HOME/project/sub"
NOPROJECT_OUT="$(cd "$FAKE_HOME/project/sub" && HOME="$FAKE_HOME" bash "$HERE/scripts/mc.sh" 2>&1)"; NOPROJECT_RC=$?
chk "no-project: exits non-zero"        "[ \"\$NOPROJECT_RC\" != 0 ]"
chk "no-project: exact error message"   "printf '%s' \"\$NOPROJECT_OUT\" | grep -qF 'mc: no workbench project (.claude/tasks/ + .workbench/config.json) found from $FAKE_HOME/project/sub upwards'"
chk "no-project: does not render a dashboard" "! printf '%s' \"\$NOPROJECT_OUT\" | grep -q 'Jobs'"
rm -rf "$FAKE_HOME"

[ "$fail" = 0 ] && echo "PASS: mc" || { echo "mc test failed"; exit 1; }
