#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
C="$HERE/templates/coord"
fail=0
chk() { if eval "$2"; then echo "ok: $1"; else echo "FAIL: $1" >&2; fail=1; fi; }

for f in lib.sh wb-coord with-lock.sh precommit-guard.sh bb-worktree.sh install-hooks.sh; do
  chk "coord/$f exists" "[ -f '$C/$f' ]"
done
chk "lib.sh anchors on .workbench/config.json" "grep -q '.workbench/config.json' '$C/lib.sh'"
chk "lib.sh syntactically valid"            "bash -n '$C/lib.sh'"
chk "wb-coord syntactically valid"          "bash -n '$C/wb-coord'"
chk "no beebeeb-specific paths"             "! grep -rqi 'repos/server\|beebeeb' '$C/'"
chk "commit-guard advice uses scripts/coord (no make-refs)" "! grep -q 'make coord\|make worktree' '$C/precommit-guard.sh' && grep -q 'scripts/coord/wb-coord status' '$C/precommit-guard.sh'"

[ "$fail" = 0 ] && echo "PASS: coord" || { echo "coord test failed"; exit 1; }
