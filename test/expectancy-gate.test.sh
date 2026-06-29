#!/usr/bin/env bash
# BM-5 — expectancy/conformance gate: a regression gate for the way of working. The free
# structural tier passes on a healthy repo and FAILS when an invariant the live conformance
# depends on is removed (e.g. the intent-routing table). Verified by mutating a repo copy.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATE="$ROOT/scripts/expectancy-gate.sh"
fail=0
chk() { if eval "$2"; then echo "ok: $1"; else echo "FAIL: $1" >&2; fail=1; fi; }

# passes clean on the real repo
chk "gate passes on healthy repo"   "bash '$GATE' >/dev/null 2>&1"
OUT="$(bash "$GATE" 2>&1)"
chk "reports routing table present" "printf '%s' \"\$OUT\" | grep -q 'routing table present in full'"
chk "reports harness intact"        "printf '%s' \"\$OUT\" | grep -qE 'harness intact \(simulate [0-9]+/[0-9]+\)'"

# negative: full-copy the repo (minus .git), remove the routing table, gate must FAIL.
# (a full copy so the harness's simulate scaffolding behaves exactly like the real repo)
fullcopy() { rm -rf "$1"/*; cp -r "$ROOT"/. "$1/" 2>/dev/null; rm -rf "$1/.git"; }
T="$(mktemp -d)"; fullcopy "$T"
chk "copy passes too (sanity)"      "WB_GATE_ROOT='$T' bash '$T/scripts/expectancy-gate.sh' >/dev/null 2>&1"
# strip the routing section heading from the full template
sed -i 's/## Intent routing.*/## (removed)/' "$T/templates/full/CLAUDE.md.tmpl"
NEG="$(WB_GATE_ROOT="$T" bash "$T/scripts/expectancy-gate.sh" 2>&1)"; rc=$?
chk "gate FAILS when routing table removed" "[ $rc -ne 0 ]"
chk "names the missing invariant"   "printf '%s' \"\$NEG\" | grep -q 'routing table MISSING in full'"

# negative 2: blank a command description -> fail
fullcopy "$T"   # restore
printf '%s\n' '---' 'description:' 'allowed-tools: ["Bash"]' '---' 'x' > "$T/commands/mc.md"  # empty description
rc2=0; WB_GATE_ROOT="$T" bash "$T/scripts/expectancy-gate.sh" >/dev/null 2>&1 || rc2=$?
chk "gate FAILS on empty command description" "[ $rc2 -ne 0 ]"
rm -rf "$T"

# baseline file exists for the --live tier
chk "baseline file present"         "[ -f '$ROOT/test/benchmark/baseline' ]"

[ "$fail" = 0 ] && echo "PASS: expectancy-gate" || { echo "expectancy-gate test failed"; exit 1; }
