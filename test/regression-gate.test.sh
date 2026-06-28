#!/usr/bin/env bash
# SQ-5 — global regression gate: runs the project's FULL checks before verify, flags
# was-green-now-red against a baseline, level-scaled (block crew/fleet, advisory solo/pair).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RG="$HERE/scripts/regression-gate.sh"
fail=0
chk() { if eval "$2"; then echo "ok: $1"; else echo "FAIL: $1" >&2; fail=1; fi; }
rc_of() { "$@" >/dev/null 2>&1; echo $?; }
setchecks() { python3 - "$1" "$2" <<'PY'
import json,sys
c=json.load(open(sys.argv[1])); c.setdefault("project",{})["checks"]=json.loads(sys.argv[2])
json.dump(c,open(sys.argv[1],'w'),indent=2)
PY
}

DIR="$(mktemp -d)"
bash "$HERE/scripts/init.sh" --name "Reg Co" --level crew --target "$DIR" >/dev/null 2>&1

# no checks configured -> clean skip
chk "no checks -> exit 0"        "[ \"\$(rc_of bash '$RG' --target '$DIR')\" -eq 0 ]"
chk "no checks -> says SKIP"     "bash '$RG' --target '$DIR' 2>&1 | grep -q SKIP"

# all green
setchecks "$DIR/.workbench/config.json" '["true","true"]'
chk "all green -> exit 0"        "[ \"\$(rc_of bash '$RG' --target '$DIR')\" -eq 0 ]"
chk "all green -> says green"    "bash '$RG' --target '$DIR' 2>&1 | grep -q 'all green'"

# a check fails at crew -> BLOCK exit 3 + warn suggestion
setchecks "$DIR/.workbench/config.json" '["true","false"]'
chk "red at crew -> BLOCK 3"     "[ \"\$(rc_of bash '$RG' --target '$DIR')\" -eq 3 ]"
chk "red -> warn suggestion"     "[ -f '$DIR/.workbench/suggestions/regression.suggest' ] && grep -q '^severity=warn\$' '$DIR/.workbench/suggestions/regression.suggest'"

# was-green-now-red: SAME command flips pass->fail via a marker file. The transition is
# detected on the FIRST red run after a green baseline (each run rewrites the baseline),
# so capture that one run and assert both block + was-green-now-red on it.
M="$DIR/marker"; : > "$M"
setchecks "$DIR/.workbench/config.json" "[\"test -f $M\"]"
chk "marker present -> green exit 0" "[ \"\$(rc_of bash '$RG' --target '$DIR')\" -eq 0 ]"   # establishes green baseline
rm -f "$M"                                            # break it: same command now fails
TRANS="$(bash "$RG" --target "$DIR" 2>&1)"; trc=$?    # THE transition run
chk "transition -> BLOCK 3"      "[ '$trc' -eq 3 ]"
chk "transition -> was-green-now-red" "printf '%s' \"\$TRANS\" | grep -qi 'was-green-now-red'"

# advisory at solo: red but exit 0
SDIR="$(mktemp -d)"; bash "$HERE/scripts/init.sh" --name "Reg Solo" --level solo --target "$SDIR" >/dev/null 2>&1
setchecks "$SDIR/.workbench/config.json" '["false"]'
chk "red at solo -> advisory exit 0" "[ \"\$(rc_of bash '$RG' --target '$SDIR')\" -eq 0 ]"
chk "solo red -> says ADVISORY"  "bash '$RG' --target '$SDIR' 2>&1 | grep -q ADVISORY"
rm -rf "$SDIR"

rm -rf "$DIR"
[ "$fail" = 0 ] && echo "PASS: regression-gate" || { echo "regression-gate test failed"; exit 1; }
