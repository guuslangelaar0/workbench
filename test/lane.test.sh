#!/usr/bin/env bash
# P0-3 — lane heartbeat: a file-based liveness LEASE the orchestration lead trusts
# over its (stale-prone) in-memory team registry. start bumps attempts
# (restart-intensity), beat refreshes the heartbeat, reap finds stale running lanes.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # workbench
LANE="$HERE/scripts/lane.sh"
fail=0
chk() { if eval "$2"; then echo "ok: $1"; else echo "FAIL: $1" >&2; fail=1; fi; }

DIR="$(mktemp -d)"
bash "$HERE/scripts/init.sh" --name "Lane Co" --level crew --target "$DIR" >/dev/null 2>&1
LANES="$DIR/.workbench/lanes"
LF="$LANES/0001.lane"

# start: creates the lane with attempts=1, status=running, owner set
bash "$LANE" start 0001 --owner rust-engineer --target "$DIR" >/dev/null 2>&1
chk "start: lane file created"        "[ -f '$LF' ]"
chk "start: attempts=1"               "grep -q '^attempts=1\$' '$LF'"
chk "start: status=running"           "grep -q '^status=running\$' '$LF'"
chk "start: owner recorded"           "grep -q '^owner=rust-engineer\$' '$LF'"

# second start on same id == re-dispatch == restart-intensity bumps to 2
bash "$LANE" start 0001 --owner rust-engineer --target "$DIR" >/dev/null 2>&1
chk "restart: attempts=2"             "grep -q '^attempts=2\$' '$LF'"

# beat: refreshes last_beat, keeps owner + attempts
sed -i 's/^last_beat=.*/last_beat=1/' "$LF"
bash "$LANE" beat 0001 --target "$DIR" >/dev/null 2>&1
chk "beat: last_beat advanced"        "[ \"\$(sed -n 's/^last_beat=//p' '$LF')\" -gt 1000 ]"
chk "beat: owner preserved"           "grep -q '^owner=rust-engineer\$' '$LF'"
chk "beat: attempts preserved"        "grep -q '^attempts=2\$' '$LF'"

# status prints the record and exits 0
chk "status: exit 0 + prints owner"   "bash '$LANE' status 0001 --target '$DIR' 2>/dev/null | grep -q '^owner=rust-engineer\$'"
chk "status: absent -> exit 1"        "! bash '$LANE' status 9999 --target '$DIR' >/dev/null 2>&1"

# staleness: push last_beat far into the past, then reap flags it DEAD
sed -i "s/^last_beat=.*/last_beat=$(( $(date +%s) - 100000 ))/" "$LF"
REAP="$(bash "$LANE" reap --threshold 1800 --target "$DIR" 2>/dev/null)"
chk "reap: reports stale lane DEAD"   "printf '%s' \"\$REAP\" | grep -q '^0001 DEAD age='"

# --mark rewrites status=dead (and leaves it out of future running-only reaps)
bash "$LANE" reap --threshold 1800 --mark --target "$DIR" >/dev/null 2>&1
chk "reap --mark: status=dead"        "grep -q '^status=dead\$' '$LF'"

# a fresh lane is NOT reported dead
bash "$LANE" start 0002 --owner ts-engineer --target "$DIR" >/dev/null 2>&1
REAP2="$(bash "$LANE" reap --threshold 1800 --target "$DIR" 2>/dev/null)"
chk "reap: fresh lane not DEAD"       "! printf '%s' \"\$REAP2\" | grep -q '^0002 DEAD'"

# list shows both lanes, one line each
LIST="$(bash "$LANE" list --target "$DIR" 2>/dev/null)"
chk "list: shows 0001"                "printf '%s' \"\$LIST\" | grep -q '^0001 status=dead owner=rust-engineer age=.* attempts=2\$'"
chk "list: shows 0002"                "printf '%s' \"\$LIST\" | grep -q '^0002 status=running owner=ts-engineer'"

# clear removes the lane file
bash "$LANE" clear 0002 --target "$DIR" >/dev/null 2>&1
chk "clear: lane file removed"        "[ ! -f '$LANES/0002.lane' ]"

rm -rf "$DIR"
[ "$fail" = 0 ] && echo "PASS: lane" || { echo "lane test failed"; exit 1; }
