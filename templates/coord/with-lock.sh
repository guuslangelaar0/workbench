#!/usr/bin/env bash
# with-lock — globally serialize an action across all sessions on this machine.
#
# Fulfils the reusable primitive from task 0618 (deploy lock) and backs the
# commit lock (B). Lock files live at .claude/locks/<name>.lock and carry a
# heartbeat so a crashed holder's lock auto-expires.
#
# Usage:
#   scripts/coord/with-lock.sh <name> -- <command> [args...]
#   scripts/coord/with-lock.sh deploy-prod -- make prod-deploy
#
# Behaviour:
#   - If a FRESH lock (heartbeat < BB_LOCK_TTL) is held by another session,
#     refuse with a clear message naming the holder + age, exit 75 (EX_TEMPFAIL).
#   - If the lock is STALE (holder died), claim it.
#   - Refresh the heartbeat every BB_LOCK_HEARTBEAT seconds while the command
#     runs; remove the lock on exit (success or failure).
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$DIR/lib.sh"

BB_LOCK_HEARTBEAT="${BB_LOCK_HEARTBEAT:-15}"

name="${1:-}"; shift || true
[ "${1:-}" = "--" ] && shift || true
[ -n "$name" ] && [ "$#" -gt 0 ] || { echo "usage: with-lock <name> -- <command...>" >&2; exit 64; }

bb_ensure_dirs
lock="$BB_LOCKS_DIR/${name}.lock"
sid="$(bb_sid)"

write_lock() {
  printf '{"name":"%s","holder":"%s","label":"%s","pid":%s,"host":"%s","started_at":"%s","heartbeat_epoch":%s,"action":"%s"}\n' \
    "$name" "$sid" "${BB_LABEL:-}" "$$" "$(hostname -s 2>/dev/null || echo host)" "$(bb_now_iso)" "$(bb_now)" "$*" > "$lock"
}

if [ -f "$lock" ]; then
  holder="$(bb_json_get "$lock" holder || true)"
  hb="$(bb_json_get "$lock" heartbeat_epoch || echo 0)"
  if [ "$holder" != "$sid" ] && bb_is_fresh "$hb" "$BB_LOCK_TTL"; then
    age=$(( $(bb_now) - ${hb:-0} ))
    echo "${BB_RED}✗ '$name' is locked${BB_RST} by ${BB_BOLD}$(bb_sid_short "$holder")${BB_RST} (heartbeat ${age}s ago). Skipping." >&2
    exit 75
  fi
  # stale or ours → reclaim
fi

write_lock "$@"

# Background heartbeat refresher.
( while :; do sleep "$BB_LOCK_HEARTBEAT"; [ -f "$lock" ] || break
    tmp="$lock.$$"; sed "s/\"heartbeat_epoch\":[0-9]*/\"heartbeat_epoch\":$(bb_now)/" "$lock" > "$tmp" 2>/dev/null && mv "$tmp" "$lock" 2>/dev/null || break
  done ) &
hb_pid=$!

cleanup() { kill "$hb_pid" 2>/dev/null || true; rm -f "$lock" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

set +e
"$@"
rc=$?
set -e
exit "$rc"
