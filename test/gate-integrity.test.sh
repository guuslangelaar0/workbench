#!/usr/bin/env bash
# SQ-2 — anti-gaming gate-integrity guard. Heuristic detection of reward-hacking in a
# code diff: deleted/skipped/trivial tests (hard) + net assertions removed (soft).
# Blocks only when enforce(crew/fleet) + hard signal + the task claims tests pass.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GI="$HERE/scripts/gate-integrity.sh"
fail=0
chk() { if eval "$2"; then echo "ok: $1"; else echo "FAIL: $1" >&2; fail=1; fi; }
# capture exit code of a gate-integrity run (stderr+stdout discarded)
rc_of() { "$GI" "$@" >/dev/null 2>&1; echo $?; }

DIR="$(mktemp -d)"
bash "$HERE/scripts/init.sh" --name "GI Co" --level crew --target "$DIR" >/dev/null 2>&1
D="$DIR/diffs"; mkdir -p "$D"

# clean diff — no signals, exit 0
printf 'diff --git a/src/lib.rs b/src/lib.rs\n--- a/src/lib.rs\n+++ b/src/lib.rs\n@@\n+fn add(a:i32,b:i32)->i32{a+b}\n' > "$D/clean.diff"
chk "clean diff: exit 0"             "[ \"\$(rc_of --diff '$D/clean.diff' --target '$DIR')\" -eq 0 ]"
OUT="$("$GI" --diff "$D/clean.diff" --target "$DIR" 2>&1)"
chk "clean diff: says clean"         "grep -q 'clean' <<< \"\$OUT\""

# empty diff — fail open (skip), exit 0
: > "$D/empty.diff"
chk "empty diff: SKIP exit 0"        "[ \"\$(rc_of --diff '$D/empty.diff' --target '$DIR')\" -eq 0 ]"

# trivially-passing assertion added (hard), no task -> advisory exit 0
printf 'diff --git a/t_test.rs b/t_test.rs\n--- a/t_test.rs\n+++ b/t_test.rs\n@@\n+  assert!(true);\n' > "$D/trivial.diff"
chk "trivial assert: advisory exit 0" "[ \"\$(rc_of --diff '$D/trivial.diff' --target '$DIR')\" -eq 0 ]"
OUT="$("$GI" --diff "$D/trivial.diff" --target "$DIR" 2>&1)"
chk "trivial assert: flagged hard"    "grep -qi 'trivially-passing' <<< \"\$OUT\""

# skip added (hard), js
printf 'diff --git a/a.test.js b/a.test.js\n--- a/a.test.js\n+++ b/a.test.js\n@@\n+  it.skip("x", () => {})\n' > "$D/skip.diff"
OUT="$("$GI" --diff "$D/skip.diff" --target "$DIR" 2>&1)"
chk "skip added: flagged hard"        "grep -qi 'skipped/ignored' <<< \"\$OUT\""

# python skip marker
printf 'diff --git a/test_x.py b/test_x.py\n--- a/test_x.py\n+++ b/test_x.py\n@@\n+@pytest.mark.skip\n' > "$D/pyskip.diff"
OUT="$("$GI" --diff "$D/pyskip.diff" --target "$DIR" 2>&1)"
chk "pytest skip: flagged hard"       "grep -qi 'skipped/ignored' <<< \"\$OUT\""

# deleted test file (hard) + task WITHOUT pass-claim -> advisory exit 0
printf 'diff --git a/tests/auth_test.rs b/tests/auth_test.rs\ndeleted file mode 100644\n--- a/tests/auth_test.rs\n+++ /dev/null\n@@\n-#[test]\n-fn it(){ assert_eq!(2,2); }\n' > "$D/del.diff"
printf '# 0123 — thing\n## Notes\nrefactor only\n' > "$D/task-nopass.md"
chk "deleted test, no pass-claim: exit 0" "[ \"\$(rc_of --diff '$D/del.diff' --task '$D/task-nopass.md' --target '$DIR')\" -eq 0 ]"
OUT="$("$GI" --diff "$D/del.diff" --target "$DIR" 2>&1)"
chk "deleted test: names the file"        "grep -q 'tests/auth_test.rs' <<< \"\$OUT\""

# deleted test (hard) + task WITH pass-claim + crew -> BLOCK exit 3
printf '# 0123 — thing\n## Verification evidence\nAll tests pass (cargo test green).\n' > "$D/task-pass.md"
chk "deleted+pass-claim+crew: BLOCK 3" "[ \"\$(rc_of --diff '$D/del.diff' --task '$D/task-pass.md' --target '$DIR')\" -eq 3 ]"

# same at solo (advisory level) -> NOT blocked
SDIR="$(mktemp -d)"; bash "$HERE/scripts/init.sh" --name "Solo GI" --level solo --target "$SDIR" >/dev/null 2>&1
chk "deleted+pass-claim+solo: exit 0" "[ \"\$(rc_of --diff '$D/del.diff' --task '$D/task-pass.md' --target '$SDIR')\" -eq 0 ]"
rm -rf "$SDIR"

# --strict blocks on any hard signal regardless of pass-claim
chk "strict: trivial -> BLOCK 3"      "[ \"\$(rc_of --diff '$D/trivial.diff' --strict --target '$DIR')\" -eq 3 ]"

# net assertion drop only (soft) -> advisory, not blocked even with --strict
printf 'diff --git a/m_test.rs b/m_test.rs\n--- a/m_test.rs\n+++ b/m_test.rs\n@@\n-assert_eq!(a,b);\n-assert_eq!(c,d);\n+let x=1;\n' > "$D/soft.diff"
chk "soft drop: advisory exit 0"      "[ \"\$(rc_of --diff '$D/soft.diff' --target '$DIR')\" -eq 0 ]"
chk "soft drop: not strict-blocked"   "[ \"\$(rc_of --diff '$D/soft.diff' --strict --target '$DIR')\" -eq 0 ]"
OUT="$("$GI" --diff "$D/soft.diff" --target "$DIR" 2>&1)"
chk "soft drop: reports net removed"  "grep -qi 'net assertion' <<< \"\$OUT\""

# files a warn suggestion onto the surface
bash "$GI" --diff "$D/del.diff" --key gaming-0777 --target "$DIR" >/dev/null 2>&1
chk "files a warn suggestion"         "[ -f '$DIR/.workbench/suggestions/gaming-0777.suggest' ] && grep -q '^severity=warn\$' '$DIR/.workbench/suggestions/gaming-0777.suggest'"

rm -rf "$DIR"
[ "$fail" = 0 ] && echo "PASS: gate-integrity" || { echo "gate-integrity test failed"; exit 1; }
