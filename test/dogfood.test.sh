#!/usr/bin/env bash
# Dogfood: scaffold a full project and exercise the whole assembled surface end-to-end
# (init → tasks → lifecycle → mc → coord claims → drift → ground-brief). Catches
# integration regressions the per-unit suites miss.
set -uo pipefail
# exercises lifecycle MOVE mechanics, not the verification contract
# (covered by verification-gate.test.sh) — bypass the ->verified gate
export WB_SKIP_VERIFY_GATE=1
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # workbench
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail=0
chk() { if eval "$2"; then echo "ok: $1"; else echo "FAIL: $1" >&2; fail=1; fi; }

bash "$HERE/scripts/init.sh" --name "Dogfood" --mission "Prove it works end to end." --target "$TMP" --profile full >/dev/null 2>&1

# a fresh scaffold must be drift-clean (manifest matches the rendered files)
chk "fresh scaffold is drift-clean" "! bash '$HERE/scripts/drift.sh' '$TMP' 2>/dev/null | grep -qE ' edited| missing'"

# seed two tasks, move one through the full lifecycle
bash "$HERE/scripts/task-new.sh" --title "First Capability" --track core --estimate "~1d" --target "$TMP" >/dev/null
bash "$HERE/scripts/task-new.sh" --title "Second Capability" --track core --target "$TMP" >/dev/null
chk "two tasks seeded in backlog" "[ \"\$(ls '$TMP'/.claude/tasks/backlog/*.md 2>/dev/null | wc -l | tr -d ' ')\" = 2 ]"
for st in in-development in-review verified; do
  bash "$HERE/scripts/task-move.sh" 0001 "$st" --target "$TMP" >/dev/null
done
V="$TMP/.claude/tasks/verified/0001-first-capability.md"
chk "task 0001 reached verified"  "[ -f '$V' ]"
chk "verified task status correct" "grep -q '^\\*\\*Status:\\*\\* verified' '$V'"

# mc renders the assembled state
mc="$(cd "$TMP" && bash "$HERE/scripts/mc.sh" --no-prod --no-build 2>/dev/null)"
chk "mc names the project"        "printf '%s' \"\$mc\" | grep -q Dogfood"
chk "mc shows verified + backlog" "printf '%s' \"\$mc\" | grep -q verified && printf '%s' \"\$mc\" | grep -q backlog"

# coordination claim is visible cross-session
export WB_WORKSPACE_ROOT="$TMP"
WB_SID_OVERRIDE=df1 bash "$TMP/scripts/coord/wb-coord" claim task:0002 >/dev/null 2>&1
chk "coord claim visible cross-session" "WB_SID_OVERRIDE=df2 bash '$TMP/scripts/coord/wb-coord' claims task:0002 >/dev/null 2>&1"
unset WB_WORKSPACE_ROOT

# the SessionStart operating brief reflects disk reality
chk "ground brief names the project + counts" "gs_out=\$(CLAUDE_PROJECT_DIR='$TMP' bash '$HERE/hooks/bin/ground-session.sh' 2>/dev/null); printf '%s' \"\$gs_out\" | grep -q 'Dogfood'"

[ "$fail" = 0 ] && echo "PASS: dogfood" || { echo "dogfood test failed"; exit 1; }
