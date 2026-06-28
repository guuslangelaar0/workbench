#!/usr/bin/env bash
# SQ-3 — cost/budget governance. Exact token spend from the transcript (usage-sum),
# snapshotted by the usage-meter hook, governed by a token ceiling (downshift→pause).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUM="$HERE/scripts/usage-sum.sh"; BUD="$HERE/scripts/budget.sh"; METER="$HERE/hooks/bin/usage-meter.sh"
fail=0
chk() { if eval "$2"; then echo "ok: $1"; else echo "FAIL: $1" >&2; fail=1; fi; }
rc_of() { "$@" >/dev/null 2>&1; echo $?; }

DIR="$(mktemp -d)"
bash "$HERE/scripts/init.sh" --name "Budget Co" --level crew --target "$DIR" >/dev/null 2>&1
JL="$DIR/session.jsonl"
cat > "$JL" <<'EOF'
{"type":"user","message":{"role":"user","content":"hi"}}
{"type":"assistant","message":{"model":"claude-opus-4-8","role":"assistant","usage":{"input_tokens":1000,"output_tokens":200,"cache_read_input_tokens":50,"cache_creation_input_tokens":300}}}
{"type":"assistant","message":{"model":"claude-opus-4-8","role":"assistant","usage":{"input_tokens":2000,"output_tokens":500,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"cache_creation":{"ephemeral_1h_input_tokens":99999}}}}
EOF

# usage-sum: exact, and the nested ephemeral_*_input_tokens must NOT inflate input
SUMOUT="$(bash "$SUM" "$JL")"
chk "usage-sum: input=3000 (nested ignored)" "[ \"\$(printf '%s' \"$SUMOUT\" | cut -f1)\" = 3000 ]"
chk "usage-sum: output=700"                  "[ \"\$(printf '%s' \"$SUMOUT\" | cut -f2)\" = 700 ]"
chk "usage-sum: cache_write=300"             "[ \"\$(printf '%s' \"$SUMOUT\" | cut -f4)\" = 300 ]"
chk "usage-sum: turns=2"                      "[ \"\$(printf '%s' \"$SUMOUT\" | cut -f5)\" = 2 ]"
chk "usage-sum: source exact"                 "[ \"\$(printf '%s' \"$SUMOUT\" | cut -f6)\" = exact ]"

# usage-sum fails open on a missing file
chk "usage-sum: missing file -> none, exit 0" "[ \"\$(bash '$SUM' /nope/x.jsonl | cut -f6)\" = none ]"

# meter hook: parses stdin payload, writes the snapshot, fails open without a project
SNAP="$DIR/.workbench/usage/current.tsv"
printf '{"session_id":"s1","transcript_path":"%s","hook_event_name":"Stop"}' "$JL" | CLAUDE_PROJECT_DIR="$DIR" bash "$METER"
chk "meter: snapshot written"     "[ -f '$SNAP' ]"
chk "meter: snapshot has session" "grep -q '^s1	' '$SNAP'"
chk "meter: snapshot input col"   "[ \"\$(cut -f3 '$SNAP')\" = 3000 ]"
chk "meter: fails open (exit 0) without payload" "[ \"\$(printf '' | rc_of bash '$METER')\" = 0 ]"

# budget set + show
bash "$BUD" set --ceiling-tokens 4000 --on-approach downshift --approach-pct 80 --target "$DIR" >/dev/null 2>&1
chk "set: ceiling persisted"      "grep -q '\"ceiling_tokens\": 4000' '$DIR/.workbench/config.json'"
SHOW="$(bash "$BUD" show --target "$DIR" 2>/dev/null)"
chk "show: billable total 4.0k"   "printf '%s' \"\$SHOW\" | grep -q 'billable total: 4.0k'"
chk "show: 100% used"             "printf '%s' \"\$SHOW\" | grep -q '100% used'"

# check: billable = 3000+700+300 = 4000 >= 4000 -> OVER (exit 3) + warn suggestion
chk "check: over ceiling exit 3"  "[ \"\$(rc_of bash '$BUD' check --target '$DIR')\" -eq 3 ]"
chk "check: filed budget-over"    "[ -f '$DIR/.workbench/suggestions/budget-over.suggest' ]"
chk "over suggestion is warn"     "grep -q '^severity=warn\$' '$DIR/.workbench/suggestions/budget-over.suggest'"

# raise ceiling so spend is ~57% -> ok (below approach), exit 0
bash "$BUD" set --ceiling-tokens 7000 --target "$DIR" >/dev/null 2>&1
chk "check: under ceiling exit 0" "[ \"\$(rc_of bash '$BUD' check --target '$DIR')\" -eq 0 ]"

# approach band: ceiling 4800 -> 4000/4800 = 83% >= 80% -> approaching, exit 0 + recommend suggestion
bash "$BUD" set --ceiling-tokens 4800 --target "$DIR" >/dev/null 2>&1
chk "check: approaching exit 0"   "[ \"\$(rc_of bash '$BUD' check --target '$DIR')\" -eq 0 ]"
chk "check: filed budget-approach" "[ -f '$DIR/.workbench/suggestions/budget-approach.suggest' ]"

# no ceiling set -> check is a clean no-op
ND="$(mktemp -d)"; bash "$HERE/scripts/init.sh" --name N --level crew --target "$ND" >/dev/null 2>&1
chk "check: no ceiling -> exit 0" "[ \"\$(rc_of bash '$BUD' check --target '$ND')\" -eq 0 ]"
rm -rf "$ND"

# per-task ledger delta — start at current cumulative (4000)
bash "$BUD" task 0042 start --target "$DIR" >/dev/null 2>&1
# simulate more spend: append a turn, re-meter
cat >> "$JL" <<'EOF'
{"type":"assistant","message":{"role":"assistant","usage":{"input_tokens":500,"output_tokens":100,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}
EOF
printf '{"session_id":"s1","transcript_path":"%s"}' "$JL" | CLAUDE_PROJECT_DIR="$DIR" bash "$METER"
CLOSE="$(bash "$BUD" task 0042 close --target "$DIR" 2>/dev/null)"
chk "task close: delta ≈ 600 tokens" "printf '%s' \"\$CLOSE\" | grep -q '600 tokens'"
chk "ledger: has a delta= row"        "grep -q 'delta=600' '$DIR/.workbench/ledger.tsv'"

rm -rf "$DIR"
[ "$fail" = 0 ] && echo "PASS: budget" || { echo "budget test failed"; exit 1; }
