#!/usr/bin/env bash
# Behavioral: notify.sh (gating + dryrun).
# Presence: hooks.json wiring, the hook scripts, the remote skill + command.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # workbench
S="$HERE/skills"; C="$HERE/commands"; B="$HERE/hooks/bin"; HJ="$HERE/hooks/hooks.json"
NOTIFY="$B/notify.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail=0
chk() { if eval "$2"; then echo "ok: $1"; else echo "FAIL: $1" >&2; fail=1; fi; }

bash "$HERE/scripts/init.sh" --name "Acme" --mission "Test." --target "$TMP" --profile full --level fleet >/dev/null 2>&1
CFG="$TMP/.workbench/config.json"

# flip remote on
sed -i.bak 's/"remote": "off"/"remote": "telegram"/' "$CFG" && rm -f "$CFG.bak"

# --- notify gating ---
# remote=off → silent no-op
TMP2="$(mktemp -d)"; bash "$HERE/scripts/init.sh" --name "Off" --target "$TMP2" --profile full --level fleet >/dev/null 2>&1
o_off="$(CLAUDE_PROJECT_DIR="$TMP2" WORKBENCH_NOTIFY_DRYRUN=1 bash "$NOTIFY" 2>/dev/null || true)"
chk "notify no-ops when remote=off"  "[ -z \"$o_off\" ]"
rm -rf "$TMP2"
# remote=telegram but no creds → no-op
o_nc="$(CLAUDE_PROJECT_DIR="$TMP" WORKBENCH_TELEGRAM_ENV="$TMP/none.env" WORKBENCH_NOTIFY_DRYRUN=1 bash "$NOTIFY" 2>/dev/null || true)"
chk "notify no-ops without creds"    "[ -z \"$o_nc\" ]"
# remote=telegram + creds + dryrun → prints a send target naming the project + chat
ENVF="$TMP/tg.env"; printf 'TELEGRAM_BOT_TOKEN=DRYRUN\nTELEGRAM_CHAT_ID=123\n' > "$ENVF"
o_send="$(CLAUDE_PROJECT_DIR="$TMP" WORKBENCH_TELEGRAM_ENV="$ENVF" WORKBENCH_NOTIFY_DRYRUN=1 bash "$NOTIFY" 2>/dev/null || true)"
chk "notify dryrun sends when set"   "printf '%s' \"$o_send\" | grep -q 'chat=123'"
chk "notify names the project"       "printf '%s' \"$o_send\" | grep -q 'Acme'"

# --- hooks.json wiring ---
chk "hooks.json valid JSON"          "python3 -m json.tool '$HJ' >/dev/null"
chk "hooks.json has Notification"    "grep -q '\"Notification\"' '$HJ'"
chk "hooks.json wires notify.sh"     "grep -q 'notify.sh' '$HJ'"

# --- hook scripts present + valid ---
chk "notify.sh exists"               "[ -f '$NOTIFY' ]"
chk "notify valid bash"              "bash -n '$NOTIFY'"

# --- skill + command presence ---
chk "remote skill exists"            "[ -f '$S/remote/SKILL.md' ]"
chk "remote skill covers Channels"   "grep -qi 'channels' '$S/remote/SKILL.md'"
chk "remote skill security model"    "grep -qiE 'allowlist|never .* git' '$S/remote/SKILL.md'"
chk "remote skill disk fallback"     "grep -q 'decisions/' '$S/remote/SKILL.md'"
chk "remote command exists"          "[ -f '$C/remote.md' ]"
chk "remote command frontmatter"     "head -1 '$C/remote.md' | grep -q '^---'"

[ "$fail" = 0 ] && echo "PASS: remote" || { echo "remote test failed"; exit 1; }
