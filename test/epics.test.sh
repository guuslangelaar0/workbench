#!/usr/bin/env bash
# Spec 2 — epics & lifecycle file model: epic creation, task↔epic linkage, the shared
# global ID counter, level-gating of the epics dir, and the mc rollup.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # workbench
fail=0
chk() { if eval "$2"; then echo "ok: $1"; else echo "FAIL: $1" >&2; fail=1; fi; }

# --- level-gating: solo (decomposition=tasks) has NO epics dir; crew does ---
S="$(mktemp -d)"; bash "$HERE/scripts/init.sh" --name "S" --level solo --target "$S" >/dev/null 2>&1
chk "solo: no epics dir"        "[ ! -d '$S/.claude/epics' ]"
C="$(mktemp -d)"; bash "$HERE/scripts/init.sh" --name "C" --level crew --target "$C" >/dev/null 2>&1
chk "crew: epics dir created"   "[ -d '$C/.claude/epics' ]"

# --- epic creation + shared ID counter (epics and tasks never collide) ---
bash "$HERE/scripts/epic-new.sh" --title "Folder Sharing & Links" --theme collab --target "$C" >/dev/null
EID="$(ls "$C/.claude/epics" | head -1 | sed 's/-.*//')"
chk "epic file created"               "[ -n '$EID' ] && [ -f \"\$(ls '$C'/.claude/epics/${EID}-*.md)\" ]"
EF="$(ls "$C"/.claude/epics/${EID}-*.md)"
chk "epic title rendered (with &)"    "grep -q 'Folder Sharing & Links' '$EF'"
chk "epic status open by default"     "grep -qE '^\\*\\*Status:\\*\\* open' '$EF'"
chk "epic theme rendered"             "grep -q 'collab' '$EF'"

# next task draws the NEXT id (epic consumed one) — proves the shared counter
bash "$HERE/scripts/task-new.sh" --title "Share dialog" --epic "$EID" --target "$C" >/dev/null
TID="$(ls "$C/.claude/tasks/backlog" | head -1 | sed 's/-.*//')"
chk "task id != epic id (shared counter advanced)" "[ '$TID' != '$EID' ]"
TF="$(ls "$C"/.claude/tasks/backlog/${TID}-*.md)"
chk "task carries the epic link"      "grep -qE '^\\*\\*Epic:\\*\\* *${EID}( |$)' '$TF'"

# a task without --epic shows (none)
bash "$HERE/scripts/task-new.sh" --title "Unrelated" --target "$C" >/dev/null
UF="$(ls "$C"/.claude/tasks/backlog/*unrelated*.md)"
chk "task without --epic shows (none)" "grep -qE '^\\*\\*Epic:\\*\\* *\\(none\\)' '$UF'"

# --- mc rollup: epic appears with a child-task count ---
bash "$HERE/scripts/task-new.sh" --title "Link expiry" --epic "$EID" --target "$C" >/dev/null
# move the share-dialog task to verified to exercise the done-count
bash "$HERE/scripts/task-move.sh" "$TID" in-development --target "$C" >/dev/null 2>&1
bash "$HERE/scripts/task-move.sh" "$TID" in-review --target "$C" >/dev/null 2>&1
bash "$HERE/scripts/task-move.sh" "$TID" verified --target "$C" >/dev/null 2>&1
MC="$(cd "$C" && NO_COLOR=1 bash "$HERE/scripts/mc.sh" --no-prod --no-build 2>/dev/null)"
chk "mc shows Epics section"          "printf '%s' \"\$MC\" | grep -q 'Epics'"
chk "mc rollup: epic + 2 child tasks" "printf '%s' \"\$MC\" | grep -qE '${EID}.*Folder Sharing & Links.*2 tasks'"
chk "mc rollup: 1 of 2 done"          "printf '%s' \"\$MC\" | grep -qE '${EID}.*1/2 tasks done'"

# --- validation: bad status rejected ---
chk "epic-new rejects bad status" "! bash '$HERE/scripts/epic-new.sh' --title x --status bogus --target '$C' >/dev/null 2>&1"

rm -rf "$S" "$C"
[ "$fail" = 0 ] && echo "PASS: epics" || { echo "epics test failed"; exit 1; }
