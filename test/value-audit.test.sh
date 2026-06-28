#!/usr/bin/env bash
# SQ-8 — value/north-star drift audit. A cadence trigger (not a judge): when N tasks have
# closed since the last audit, surface a recommend-only suggestion with the data packet
# (recent closes + charter goal); `done` resets the cadence. Auto-resolves when not due.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VA="$HERE/scripts/value-audit.sh"
fail=0
chk() { if eval "$2"; then echo "ok: $1"; else echo "FAIL: $1" >&2; fail=1; fi; }
has() { [ -f "$1/.workbench/suggestions/value-audit.suggest" ] && grep -q '^status=open$' "$1/.workbench/suggestions/value-audit.suggest"; }

DIR="$(mktemp -d)"
bash "$HERE/scripts/init.sh" --name "Val Co" --level crew --target "$DIR" >/dev/null 2>&1
printf '# Charter\n## Goal\nShip zero-knowledge sync by Friday.\n' > "$DIR/.workbench/loop-charter.md"
V="$DIR/.claude/tasks/verified"
mk() { for i in $(seq "$1" "$2"); do printf '# %04d — feature %d\n' "$i" "$i" > "$V/$(printf %04d "$i")-f.md"; done; }

chk "0 closes: not due, nothing filed"   "bash '$VA' check --cadence 3 --target '$DIR' >/dev/null 2>&1; ! has '$DIR'"
mk 1 2
chk "2 closes < cadence 3: not due"      "bash '$VA' check --cadence 3 --target '$DIR' >/dev/null 2>&1; ! has '$DIR'"
mk 3 3
bash "$VA" check --cadence 3 --target "$DIR" >/dev/null 2>&1
chk "3 closes: DUE, recommend filed"     "has '$DIR' && grep -q '^severity=recommend\$' '$DIR/.workbench/suggestions/value-audit.suggest'"
chk "packet includes charter goal"       "grep -q 'zero-knowledge sync' '$DIR/.workbench/suggestions/value-audit.suggest'"
chk "packet includes a recent close"     "grep -q 'feature 3' '$DIR/.workbench/suggestions/value-audit.suggest'"

# done resets the cadence and clears the suggestion
bash "$VA" done --target "$DIR" >/dev/null 2>&1
chk "done: cleared the suggestion"       "[ ! -f '$DIR/.workbench/suggestions/value-audit.suggest' ]"
chk "done: not due again (delta 0)"      "bash '$VA' check --cadence 3 --target '$DIR' >/dev/null 2>&1; ! has '$DIR'"

# more closes after done -> due again; then dropping below cadence auto-resolves
mk 4 6
bash "$VA" check --cadence 3 --target "$DIR" >/dev/null 2>&1
chk "3 more closes after done: DUE"      "has '$DIR'"
# config-driven cadence (audit.cadence) honored when no --cadence flag
python3 - "$DIR/.workbench/config.json" <<'PY'
import json,sys
c=json.load(open(sys.argv[1])); c["audit"]={"cadence":99}; json.dump(c,open(sys.argv[1],'w'),indent=2)
PY
bash "$VA" done --target "$DIR" >/dev/null 2>&1
mk 7 9
chk "config cadence 99: 3 closes not due" "bash '$VA' check --target '$DIR' >/dev/null 2>&1; ! has '$DIR'"

rm -rf "$DIR"
[ "$fail" = 0 ] && echo "PASS: value-audit" || { echo "value-audit test failed"; exit 1; }
