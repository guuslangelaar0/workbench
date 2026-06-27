#!/usr/bin/env bash
# workbench StopFailure hook → records a recovery marker when a turn ends on an API
# error (rate_limit / overloaded / server_error / Anthropic outage). A hook CANNOT
# resume the session itself, and in-session ScheduleWakeup crons die with the session,
# so this only LEAVES A BREADCRUMB; the EXTERNAL watchdog (scripts/watchdog.sh, run by
# cron/systemd) is what actually relaunches the loop with `claude --resume`.
#
# Reads the hook's JSON event from stdin best-effort (jq-free, grep/sed) and ALWAYS
# fails open — it must never hard-error a user's session. Marker is written at
# $(il_cfg_dir <project>)/recovery/last-failure with two lines:
#   <epoch-seconds>
#   <category>            (rate_limit|overloaded|server_error|api_error|unknown)
# If Telegram creds are present (TELEGRAM_BOT_TOKEN + TELEGRAM_CHAT_ID, same env file
# as notify.sh) it best-effort pings once; absence of curl/env is never fatal.
# WORKBENCH_TELEGRAM_ENV overrides the env path (used by tests).
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SELF_DIR/../../scripts/lib.sh" 2>/dev/null || true

P="${CLAUDE_PROJECT_DIR:-$PWD}"

# Resolve the config dir. If lib.sh failed to source for any reason, degrade to a
# sane default so we still fail open rather than erroring.
if command -v il_cfg_dir >/dev/null 2>&1; then
  CFG="$(il_cfg_dir "$P")"
else
  if [ -d "$P/.workbench" ]; then CFG="$P/.workbench"
  elif [ -d "$P/.initlab" ]; then CFG="$P/.initlab"
  else CFG="$P/.workbench"; fi
fi

# Read the event payload (best-effort; empty stdin is fine).
input="$(cat 2>/dev/null || true)"

# Categorise the failure, jq-free. Match the known Anthropic error 'type' values first;
# fall back to a generic api_error if an "error" field is present, else unknown.
category="unknown"
if printf '%s' "$input" | grep -qiE 'rate[_-]?limit'; then
  category="rate_limit"
elif printf '%s' "$input" | grep -qiE 'overloaded'; then
  category="overloaded"
elif printf '%s' "$input" | grep -qiE 'server_error|internal_server|5[0-9][0-9]'; then
  category="server_error"
elif printf '%s' "$input" | grep -qiE '"(error|error_type|type)"[[:space:]]*:|api[_-]?error|"is_api_error"[[:space:]]*:[[:space:]]*true'; then
  category="api_error"
fi

# Best-effort timestamp. The env may export EPOCHSECONDS (bash 5); otherwise use date.
now="${EPOCHSECONDS:-}"
[ -n "$now" ] || now="$(date +%s 2>/dev/null || echo 0)"

# Write the marker. mkdir -p may fail on a read-only / nonexistent parent — tolerate it.
if mkdir -p "$CFG/recovery" 2>/dev/null; then
  {
    printf '%s\n' "$now"
    printf '%s\n' "$category"
  } > "$CFG/recovery/last-failure" 2>/dev/null || true
fi

# Optional Telegram nudge (same creds/contract as notify.sh). All best-effort.
ENVF="${WORKBENCH_TELEGRAM_ENV:-$HOME/.claude/channels/telegram/.env}"
if [ -f "$ENVF" ]; then
  # shellcheck disable=SC1090
  . "$ENVF" 2>/dev/null || true
  BOT="${TELEGRAM_BOT_TOKEN:-}"; CHAT="${TELEGRAM_CHAT_ID:-}"
  if [ -n "$BOT" ] && [ -n "$CHAT" ]; then
    text="workbench loop hit an API error: ${category} — watchdog will attempt resume"
    if [ -n "${WORKBENCH_NOTIFY_DRYRUN:-}" ]; then
      echo "DRYRUN sendMessage chat=${CHAT} text=${text}"
    else
      curl -s --max-time 5 "https://api.telegram.org/bot${BOT}/sendMessage" \
        --data-urlencode "chat_id=${CHAT}" --data-urlencode "text=${text}" >/dev/null 2>&1 || true
    fi
  fi
fi

exit 0
