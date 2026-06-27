#!/usr/bin/env bash
# P0-2 — the verification contract: verify-gate.sh + task-move.sh refusal + the
# TeammateIdle guard. Load-bearing assertions: a fresh task (placeholder criteria +
# evidence) is BLOCKED from reaching verified/ at crew, ADVISORY at solo, and the
# gate FAILS OPEN outside a workbench project.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # workbench
GATE="$HERE/scripts/verify-gate.sh"
MOVE="$HERE/scripts/task-move.sh"
GUARD="$HERE/hooks/bin/teammate-idle-guard.sh"
fail=0
chk() { if eval "$2"; then echo "ok: $1"; else echo "FAIL: $1" >&2; fail=1; fi; }

newtask() { # <dir>  -> echoes the new task id (created in backlog with placeholder contract)
  bash "$HERE/scripts/task-new.sh" --title "Gate probe" --target "$1" >/dev/null
  basename "$(ls "$1"/.claude/tasks/backlog/*.md | sort | tail -1)" | sed 's/-.*//'
}
fill() { # <task-file>  -> make acceptance criteria + evidence real
  sed -i 's/^- \[ \] \.\.\.$/- [ ] user can sign in with email + password/' "$1"
  sed -i 's/^(populated when verified.*/cargo test ok (42 tests); shot \/tmp\/x.png; commit abc1234./' "$1"
}

# ---------- verify-gate posture: crew enforces, solo advisory ----------
C="$(mktemp -d)"; bash "$HERE/scripts/init.sh" --name C --level crew --target "$C" >/dev/null 2>&1
S="$(mktemp -d)"; bash "$HERE/scripts/init.sh" --name S --level solo --target "$S" >/dev/null 2>&1

cid="$(newtask "$C")"; cfile="$(ls "$C"/.claude/tasks/backlog/${cid}-*.md)"
bash "$GATE" "$cfile" --target "$C" >/dev/null 2>&1; rc=$?
chk "crew: fresh task BLOCKED by gate (exit 3)" "[ $rc -eq 3 ]"

sid="$(newtask "$S")"; sfile="$(ls "$S"/.claude/tasks/backlog/${sid}-*.md)"
bash "$GATE" "$sfile" --target "$S" >/dev/null 2>&1; rc=$?
chk "solo: fresh task ADVISORY only (exit 0)" "[ $rc -eq 0 ]"

fill "$cfile"
bash "$GATE" "$cfile" --target "$C" >/dev/null 2>&1; rc=$?
chk "crew: filled task PASSES the gate (exit 0)" "[ $rc -eq 0 ]"

# fail open: missing file
bash "$GATE" "$C/.claude/tasks/backlog/nope.md" --target "$C" >/dev/null 2>&1; rc=$?
chk "missing task file fails open (exit 0)" "[ $rc -eq 0 ]"

# ---------- task-move.sh refuses ->verified without the contract (crew) ----------
did="$(newtask "$C")"   # a fresh, unmet task
bash "$MOVE" "$did" verified --target "$C" >/dev/null 2>&1; rc=$?
chk "crew: task-move ->verified REFUSED on unmet contract" "[ $rc -ne 0 ]"
chk "crew: refused task stayed out of verified/" "[ ! -f \"\$(ls '$C'/.claude/tasks/verified/${did}-*.md 2>/dev/null)\" ]"
WB_SKIP_VERIFY_GATE=1 bash "$MOVE" "$did" verified --target "$C" >/dev/null 2>&1; rc=$?
chk "crew: WB_SKIP_VERIFY_GATE=1 overrides the refusal" "[ $rc -eq 0 ] && ls '$C'/.claude/tasks/verified/${did}-*.md >/dev/null 2>&1"

# the filled task moves cleanly
bash "$MOVE" "$cid" verified --target "$C" >/dev/null 2>&1; rc=$?
chk "crew: filled task moves to verified/" "[ $rc -eq 0 ] && ls '$C'/.claude/tasks/verified/${cid}-*.md >/dev/null 2>&1"

# solo never blocks the move
sd="$(newtask "$S")"
bash "$MOVE" "$sd" verified --target "$S" >/dev/null 2>&1; rc=$?
chk "solo: task-move ->verified allowed (advisory)" "[ $rc -eq 0 ]"

# ---------- TeammateIdle guard ----------
gid="$(newtask "$C")"
bash "$MOVE" "$gid" in-review --target "$C" >/dev/null 2>&1   # in-review is not gated
echo '{"hook_event_name":"TeammateIdle","teammate_name":"eng"}' | CLAUDE_PROJECT_DIR="$C" bash "$GUARD" >/dev/null 2>&1; rc=$?
chk "crew: idle guard BLOCKS (exit 2) with unmet task in in-review" "[ $rc -eq 2 ]"
gfile="$(ls "$C"/.claude/tasks/in-review/${gid}-*.md)"; fill "$gfile"
echo '{}' | CLAUDE_PROJECT_DIR="$C" bash "$GUARD" >/dev/null 2>&1; rc=$?
chk "crew: idle guard ALLOWS (exit 0) once contract met" "[ $rc -eq 0 ]"
echo '{}' | CLAUDE_PROJECT_DIR="$(mktemp -d)" bash "$GUARD" >/dev/null 2>&1; rc=$?
chk "idle guard fails open (exit 0) outside a workbench project" "[ $rc -eq 0 ]"

rm -rf "$C" "$S"
[ "$fail" = 0 ] && echo "PASS: verification-gate" || { echo "verification-gate test failed"; exit 1; }
