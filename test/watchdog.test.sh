#!/usr/bin/env bash
# Hard-crash self-heal — StopFailure recovery hook + external watchdog.
# stopfailure-recover.sh writes a recovery marker (fail-open); watchdog.sh decides
# whether to relaunch the loop from that marker / SESSION_STATE.md staleness.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # workbench
HOOK="$HERE/hooks/bin/stopfailure-recover.sh"
WD="$HERE/scripts/watchdog.sh"
fail=0
chk() { if eval "$2"; then echo "ok: $1"; else echo "FAIL: $1" >&2; fail=1; fi; }

# A scaffolded project: just a .workbench dir + .claude/ (no full init.sh needed).
scaffold() { local d; d="$(mktemp -d)"; mkdir -p "$d/.workbench" "$d/.claude"; printf '%s' "$d"; }

# ── stopfailure-recover.sh ───────────────────────────────────────────────────
P="$(scaffold)"
SAMPLE='{"hook_event_name":"StopFailure","error":{"type":"rate_limit_error","message":"overloaded? no, rate_limit"}}'
out="$(printf '%s' "$SAMPLE" | CLAUDE_PROJECT_DIR="$P" WORKBENCH_TELEGRAM_ENV=/nonexistent bash "$HOOK"; echo "rc=$?")"
chk "stopfailure: exits 0"                 "printf '%s' \"$out\" | grep -q 'rc=0'"
chk "stopfailure: marker written"          "[ -f '$P/.workbench/recovery/last-failure' ]"
chk "stopfailure: marker line1 is epoch"   "head -1 '$P/.workbench/recovery/last-failure' | grep -Eq '^[0-9]+$'"
chk "stopfailure: category parsed"         "sed -n '2p' '$P/.workbench/recovery/last-failure' | grep -q 'rate_limit'"

# server_error category from an HTTP 5xx-ish payload
P2="$(scaffold)"
printf '%s' '{"error":{"type":"api_error"},"status":529,"message":"overloaded_error"}' \
  | CLAUDE_PROJECT_DIR="$P2" WORKBENCH_TELEGRAM_ENV=/nonexistent bash "$HOOK" >/dev/null 2>&1
chk "stopfailure: overloaded categorised"  "sed -n '2p' '$P2/.workbench/recovery/last-failure' | grep -q 'overloaded'"

# Fail-open: NO .workbench dir and EMPTY stdin must still exit 0.
BARE="$(mktemp -d)"   # no .workbench, no .claude
rc=0
printf '' | CLAUDE_PROJECT_DIR="$BARE" WORKBENCH_TELEGRAM_ENV=/nonexistent bash "$HOOK" >/dev/null 2>&1 || rc=$?
chk "stopfailure: fail-open exit 0 (no .workbench, empty stdin)" "[ '$rc' = 0 ]"

# ── watchdog.sh ──────────────────────────────────────────────────────────────
SID="sess-abc123"

# STALE SESSION_STATE.md → dry-run should print the resume command + session id.
W="$(scaffold)"
echo "# state" > "$W/.claude/SESSION_STATE.md"
old=$(( $(date +%s) - 7200 ))
touch -d "@$old" "$W/.claude/SESSION_STATE.md" 2>/dev/null \
  || touch -t "$(date -d @"$old" +%Y%m%d%H%M.%S 2>/dev/null)" "$W/.claude/SESSION_STATE.md" 2>/dev/null \
  || true
sout="$(bash "$WD" --session-id "$SID" --project "$W" --max-idle 1800 2>&1)"
chk "watchdog: stale prints claude --resume" "printf '%s' \"$sout\" | grep -q 'claude --resume'"
chk "watchdog: stale prints session id"      "printf '%s' \"$sout\" | grep -q '$SID'"
chk "watchdog: stale did NOT execute (dry-run note)" "printf '%s' \"$sout\" | grep -qi 'DRY-RUN'"
chk "watchdog: stale wrote no last-resume stamp"     "[ ! -f '$W/.workbench/recovery/last-resume' ]"

# MISSING SESSION_STATE.md is treated as stale → resume.
WM="$(scaffold)"   # .claude exists but no SESSION_STATE.md
mout="$(bash "$WD" --session-id "$SID" --project "$WM" 2>&1)"
chk "watchdog: missing state ⇒ resume"       "printf '%s' \"$mout\" | grep -q 'claude --resume'"

# FRESH SESSION_STATE.md → healthy, NO resume.
F="$(scaffold)"
echo "# state" > "$F/.claude/SESSION_STATE.md"   # mtime = now
fout="$(bash "$WD" --session-id "$SID" --project "$F" --max-idle 1800 2>&1)"
chk "watchdog: fresh prints NO claude --resume" "! printf '%s' \"$fout\" | grep -q 'claude --resume'"
chk "watchdog: fresh reports healthy"           "printf '%s' \"$fout\" | grep -qi 'healthy'"

# Recovery marker newer than last-resume forces a resume even with a fresh state.
R="$(scaffold)"
echo "# state" > "$R/.claude/SESSION_STATE.md"
mkdir -p "$R/.workbench/recovery"
printf '%s\nserver_error\n' "$(date +%s)" > "$R/.workbench/recovery/last-failure"
rout="$(bash "$WD" --session-id "$SID" --project "$R" 2>&1)"
chk "watchdog: fresh marker forces resume"   "printf '%s' \"$rout\" | grep -q 'claude --resume'"

# Missing --session-id is a usage error (exit 2).
rc=0; bash "$WD" --project "$P" >/dev/null 2>&1 || rc=$?
chk "watchdog: requires --session-id"        "[ '$rc' = 2 ]"

rm -rf "$P" "$P2" "$BARE" "$W" "$WM" "$F" "$R"
[ "$fail" = 0 ] && echo "PASS: watchdog" || { echo "watchdog test failed"; exit 1; }
