#!/usr/bin/env bash
# Spec 3 — adoption level detection: detect-level.sh recommends a starting level from
# git + repo signals, and never errors (stderr must stay clean — guards the grep -c bug).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # workbench
DET="$HERE/scripts/detect-level.sh"
fail=0
chk() { if eval "$2"; then echo "ok: $1"; else echo "FAIL: $1" >&2; fail=1; fi; }
mkc() { git -C "$1" -c user.email="$2" -c user.name="$2" commit -q --allow-empty -m "$3"; }

# recommended=<level> extractor; also asserts stderr is empty (the grep -c regression)
rec() { local d="$1" err out; err="$(mktemp)"; out="$(bash "$DET" "$d" 2>"$err" | sed -n 's/^recommended=//p' | head -1)"; [ -s "$err" ] && { echo "STDERR: $(cat "$err")" >&2; fail=1; }; rm -f "$err"; printf '%s' "$out"; }

D="$(mktemp -d)"

mkdir -p "$D/nogit"
chk "no-git single tree → solo"      "[ \"\$(rec '$D/nogit')\" = solo ]"

mkdir -p "$D/solo"; git -C "$D/solo" init -q >/dev/null 2>&1; mkc "$D/solo" solo@x c1
chk "1 committer, trunk → solo"      "[ \"\$(rec '$D/solo')\" = solo ]"

cp -r "$D/solo" "$D/pair"; mkc "$D/pair" two@x c2
chk "2 committers → pair"            "[ \"\$(rec '$D/pair')\" = pair ]"

cp -r "$D/solo" "$D/tagged"; git -C "$D/tagged" tag v1.0
chk "release tag → at least pair"    "[ \"\$(rec '$D/tagged')\" = pair ]"

cp -r "$D/solo" "$D/br"; git -C "$D/br" branch feature-x; git -C "$D/br" branch feature-y
chk "feature branches → pair"        "[ \"\$(rec '$D/br')\" = pair ]"

cp -r "$D/pair" "$D/crew"; mkc "$D/crew" three@x c3; mkc "$D/crew" four@x c4
chk "4 committers → crew"            "[ \"\$(rec '$D/crew')\" = crew ]"

cp -r "$D/crew" "$D/fleet"; for i in 5 6 7 8; do mkc "$D/fleet" "p$i@x" "c$i"; done
chk "8 committers → fleet"           "[ \"\$(rec '$D/fleet')\" = fleet ]"

mkdir -p "$D/multi/repos/a" "$D/multi/repos/b"; git -C "$D/multi" init -q >/dev/null 2>&1; mkc "$D/multi" solo@x c1
chk "multi-repo (1 committer) → crew" "[ \"\$(rec '$D/multi')\" = crew ]"

# always exits 0 (advisory) and prints reasoning
chk "exits 0"                         "bash '$DET' '$D/crew' >/dev/null 2>&1"
chk "prints a signal reason"          "bash '$DET' '$D/crew' 2>/dev/null | grep -q 'committers'"

rm -rf "$D"
[ "$fail" = 0 ] && echo "PASS: detect-level" || { echo "detect-level test failed"; exit 1; }
