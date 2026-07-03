#!/usr/bin/env bash
# decision-resolve.sh — a decision created in .claude/tasks/decisions/ moves out once
# the human answers it: default destination backlog/, a **Resolution-target:**
# override in the file, or an explicit --to on the command line (which wins over
# both). Exercises the same git-mv + **Status:** rewrite task-move.sh uses elsewhere.
set -uo pipefail
export WB_SKIP_VERIFY_GATE=1
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # workbench
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail=0
chk() { if eval "$2"; then echo "ok: $1"; else echo "FAIL: $1" >&2; fail=1; fi; }

bash "$HERE/scripts/init.sh" --name "Acme" --mission "Test." --target "$TMP" --profile minimal --level pair >/dev/null 2>&1

# --- default resolution target: backlog/ ---
bash "$HERE/scripts/task-new.sh" --title "Pick a billing provider" --state decisions \
  --target "$TMP" --verification "human decision recorded" >/dev/null
DID="$(ls "$TMP/.claude/tasks/decisions" | head -1 | sed 's/-.*//')"
DF_BEFORE="$TMP/.claude/tasks/decisions/${DID}-pick-a-billing-provider.md"
chk "decision file created in decisions/" "[ -f '$DF_BEFORE' ]"

bash "$HERE/scripts/decision-resolve.sh" "$DID" --outcome "Went with Mollie for EU residency." --target "$TMP" >/dev/null
DF_AFTER="$TMP/.claude/tasks/backlog/${DID}-pick-a-billing-provider.md"
chk "decision left decisions/"                  "[ ! -f '$DF_BEFORE' ]"
chk "decision moved to backlog/ by default"     "[ -f '$DF_AFTER' ]"
chk "status rewritten to backlog"               "grep -qE '^\\*\\*Status:\\*\\* backlog' '$DF_AFTER'"
chk "resolution section appended"               "grep -q '^## Resolution' '$DF_AFTER'"
chk "outcome text recorded"                     "grep -q 'Went with Mollie for EU residency.' '$DF_AFTER'"
chk "resolved-at timestamp recorded"            "grep -qE '^\\*\\*Resolved:\\*\\* [0-9]{4}-[0-9]{2}-[0-9]{2}T' '$DF_AFTER'"

# --- explicit --to overrides the default ---
bash "$HERE/scripts/task-new.sh" --title "Adopt OPAQUE now or later" --state decisions \
  --target "$TMP" --verification "human decision recorded" >/dev/null
DID2="$(ls "$TMP/.claude/tasks/decisions" | head -1 | sed 's/-.*//')"
bash "$HERE/scripts/decision-resolve.sh" "$DID2" --to in-development --target "$TMP" >/dev/null
D2F="$TMP/.claude/tasks/in-development/${DID2}-adopt-opaque-now-or-later.md"
chk "--to override moves to in-development" "[ -f '$D2F' ]"
chk "status rewritten to in-development"    "grep -qE '^\\*\\*Status:\\*\\* in-development' '$D2F'"
chk "no outcome given still records a placeholder" "grep -q 'no outcome text recorded' '$D2F'"

# --- a file-declared **Resolution-target:** wins over the default (but not --to) ---
bash "$HERE/scripts/task-new.sh" --title "Ceph or S3 for cold storage" --state decisions \
  --target "$TMP" --verification "human decision recorded" >/dev/null
DID3="$(ls "$TMP/.claude/tasks/decisions" | head -1 | sed 's/-.*//')"
D3_SRC="$TMP/.claude/tasks/decisions/${DID3}-ceph-or-s3-for-cold-storage.md"
printf '**Resolution-target:** in-development\n' >> "$D3_SRC"
bash "$HERE/scripts/decision-resolve.sh" "$DID3" --target "$TMP" >/dev/null
D3F="$TMP/.claude/tasks/in-development/${DID3}-ceph-or-s3-for-cold-storage.md"
chk "file-declared Resolution-target honored" "[ -f '$D3F' ]"

# --- unknown id is an error ---
chk "unknown decision id exits non-zero" "! bash '$HERE/scripts/decision-resolve.sh' 9999 --target '$TMP' >/dev/null 2>&1"

[ "$fail" = 0 ] && echo "PASS: decisions" || { echo "decisions test failed"; exit 1; }
