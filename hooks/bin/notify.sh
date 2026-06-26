#!/usr/bin/env bash
# initlab Notification hook → outbound Telegram ping, so you're nudged even when not
# watching the chat. Fires on permission_prompt / idle_prompt. No-ops unless this is
# an initlab project with remote != off AND Telegram credentials are present. The bot
# token + chat id live in ~/.claude/channels/telegram/.env (TELEGRAM_BOT_TOKEN,
# TELEGRAM_CHAT_ID) — NEVER in git. INITLAB_NOTIFY_DRYRUN=1 prints the would-be send
# target instead of curling (used by tests); INITLAB_TELEGRAM_ENV overrides the env path.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SELF_DIR/../../scripts/lib.sh"
P="${CLAUDE_PROJECT_DIR:-$PWD}"
_cfg="$(il_cfg_dir "$P")/config.json"
[ -f "$_cfg" ] || exit 0
remote="$(sed -n 's/.*"remote"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$_cfg" | head -1)"
[ -n "$remote" ] && [ "$remote" != off ] || exit 0

ENVF="${INITLAB_TELEGRAM_ENV:-$HOME/.claude/channels/telegram/.env}"
[ -f "$ENVF" ] || exit 0
# shellcheck disable=SC1090
. "$ENVF"
BOT="${TELEGRAM_BOT_TOKEN:-}"; CHAT="${TELEGRAM_CHAT_ID:-}"
[ -n "$BOT" ] && [ -n "$CHAT" ] || exit 0

name="$(sed -n 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$_cfg" | head -1)"
text="[${name:-initlab}] a session needs your attention (permission/idle). Check in or reply in chat."

if [ -n "${INITLAB_NOTIFY_DRYRUN:-}" ]; then
  echo "DRYRUN sendMessage chat=${CHAT} text=${text}"
  exit 0
fi
curl -s --max-time 5 "https://api.telegram.org/bot${BOT}/sendMessage" \
  --data-urlencode "chat_id=${CHAT}" --data-urlencode "text=${text}" >/dev/null 2>&1 || true
exit 0
