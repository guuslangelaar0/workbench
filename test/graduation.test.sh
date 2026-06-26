#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail=0
chk() { if eval "$2"; then echo "ok: $1"; else echo "FAIL: $1" >&2; fail=1; fi; }

# A solo project that has acquired a git tag should be nudged toward pair/crew.
P="$(mktemp -d)"; ( cd "$P" && git init -q && git config user.email a@b.c && git config user.name A )
bash "$HERE/scripts/init.sh" --profile full --level solo --name G --mission m --target "$P" >/dev/null 2>&1
( cd "$P" && git add -A && git commit -qm init && git tag v0.1.0 )
out="$(bash "$HERE/scripts/graduate.sh" "$P" 2>/dev/null)"
chk "tag triggers a recommendation"  "printf '%s' \"\$out\" | grep -qi 'recommend\|consider'"
chk "recommendation names the signal" "printf '%s' \"\$out\" | grep -qi 'tag\|release'"
chk "advisory exit 0"                 "bash '$HERE/scripts/graduate.sh' '$P' >/dev/null 2>&1; [ \$? -eq 0 ]"

# A fresh solo project with nothing notable stays quiet.
Q="$(mktemp -d)"; ( cd "$Q" && git init -q && git config user.email a@b.c && git config user.name A )
bash "$HERE/scripts/init.sh" --profile full --level solo --name H --mission m --target "$Q" >/dev/null 2>&1
chk "quiet when no signals" "[ -z \"\$(bash '$HERE/scripts/graduate.sh' '$Q' 2>/dev/null)\" ]"
rm -rf "$P" "$Q"
[ "$fail" = 0 ] && echo "PASS: graduation" || { echo "graduation test failed"; exit 1; }
