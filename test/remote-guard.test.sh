#!/usr/bin/env bash
# remote-guard.sh: the PreToolUse catastrophic-command guard for remote-driven
# sessions. These cases pin the matching against known bypasses (split flags,
# combined short flags, --force-with-lease+--force, trailing-slash home targets)
# while keeping ordinary cleanup allowed. Every case is checked on BOTH the python
# extraction path and the grep/sed fallback (WORKBENCH_GUARD_NO_PYTHON=1).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # workbench
G="$HERE/hooks/bin/remote-guard.sh"
fail=0
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/.workbench"
printf '%s\n' '{ "workbench": {"level":"solo"}, "project":{"name":"X","kind":"existing"}, "way_of_working":{"remote":"telegram"}, "lifecycle":{"in_review_cap":10} }' > "$TMP/.workbench/config.json"

# <expect 0|2> <command>
chk() {
  local exp="$1" c="$2" rc rc2
  printf '{"tool_input":{"command":"%s"}}' "$c" | CLAUDE_PROJECT_DIR="$TMP" bash "$G" >/dev/null 2>&1; rc=$?
  printf '{"tool_input":{"command":"%s"}}' "$c" | WORKBENCH_GUARD_NO_PYTHON=1 CLAUDE_PROJECT_DIR="$TMP" bash "$G" >/dev/null 2>&1; rc2=$?
  if [ "$rc" = "$exp" ] && [ "$rc2" = "$exp" ]; then echo "ok: ($exp) $c"
  else echo "FAIL: expected $exp, got py=$rc nopy=$rc2 for: $c" >&2; fail=1; fi
}

# --- must BLOCK (exit 2) ---
chk 2 'rm -rf /'
chk 2 'rm -r -f /'            # split flags
chk 2 'rm -fr /'
chk 2 'rm -rf /*'
chk 2 'rm -Rf /'             # combined cluster, capital R
chk 2 'rm -rf ~'
chk 2 'rm -rf $HOME'
chk 2 'rm -rf $HOME/'         # trailing slash
chk 2 'rm -rf $HOME/*'
chk 2 'rm -rf ${HOME}'
chk 2 'rm --recursive --force /'
chk 2 'rm --no-preserve-root -rf /'
chk 2 'git push --force'
chk 2 'git push --force-with-lease --force'   # lease + plain force
chk 2 'git push -xf'                          # combined short flags
chk 2 'git push -f origin main'

# --- must ALLOW (exit 0) ---
chk 0 'rm -rf ~/project'      # subpath cleanup
chk 0 'rm -rf $HOME/build'
chk 0 'rm -rf ./build'
chk 0 'rm -f /tmp/x'          # force but not recursive
chk 0 'rm -rf $HOMEDIR'       # different var, not a home target
chk 0 'git push origin main'
chk 0 'git push --force-with-lease'
chk 0 'git push --force-with-lease=origin'
chk 0 'ls -la /'

# --- gating: must NO-OP (exit 0) when remote is off ---
printf '%s\n' '{ "workbench": {"level":"solo"}, "project":{"name":"X","kind":"existing"}, "way_of_working":{"remote":"off"}, "lifecycle":{"in_review_cap":10} }' > "$TMP/.workbench/config.json"
out_rc=0; printf '{"tool_input":{"command":"rm -rf /"}}' | CLAUDE_PROJECT_DIR="$TMP" bash "$G" >/dev/null 2>&1 || out_rc=$?
[ "$out_rc" = 0 ] && echo "ok: no-op when remote=off (even for rm -rf /)" || { echo "FAIL: should no-op when remote=off, got $out_rc" >&2; fail=1; }

[ "$fail" = 0 ] && echo "PASS: remote-guard" || { echo "remote-guard test failed"; exit 1; }
