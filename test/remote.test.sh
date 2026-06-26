#!/usr/bin/env bash
# Behavioral: remote-guard.sh (block/allow exit codes) + notify.sh (gating + dryrun).
# Presence: hooks.json wiring, the hook scripts, the remote skill + command.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # workbench
S="$HERE/skills"; C="$HERE/commands"; B="$HERE/hooks/bin"; HJ="$HERE/hooks/hooks.json"
GUARD="$B/remote-guard.sh"; NOTIFY="$B/notify.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail=0
chk() { if eval "$2"; then echo "ok: $1"; else echo "FAIL: $1" >&2; fail=1; fi; }

bash "$HERE/scripts/init.sh" --name "Acme" --mission "Test." --target "$TMP" --profile full >/dev/null 2>&1
CFG="$TMP/.workbench/config.json"

# feed a Bash command to the guard as PreToolUse JSON; assert block (rc!=0) or allow (rc=0)
gtest() { # <label> <block|allow> <command...>
  local label="$1" expect="$2"; shift 2
  printf '{"tool_name":"Bash","tool_input":{"command":"%s"}}' "$*" \
    | CLAUDE_PROJECT_DIR="$TMP" bash "$GUARD" >/dev/null 2>&1
  local rc=$?
  if { [ "$expect" = block ] && [ "$rc" -ne 0 ]; } || { [ "$expect" = allow ] && [ "$rc" -eq 0 ]; }; then
    echo "ok: $label"; else echo "FAIL: $label (rc=$rc, expected $expect)" >&2; fail=1; fi
}

# remote=off (default scaffold): the guard must no-op even on a catastrophic command
gtest "guard no-ops when remote=off" allow "rm -rf /"

# flip remote on
sed -i.bak 's/"remote": "off"/"remote": "telegram"/' "$CFG" && rm -f "$CFG.bak"

# catastrophic → BLOCK
gtest "blocks rm -rf /"              block "rm -rf /"
gtest "blocks rm -rf /*"             block "rm -rf /*"
gtest "blocks rm -rf ~"              block "rm -rf ~"
gtest "blocks rm -rf ~/"            block "rm -rf ~/"
gtest "blocks rm -rf \$HOME"         block "rm -rf \$HOME"
gtest "blocks rm -fr ~"              block "rm -fr ~"
gtest "blocks --no-preserve-root"    block "rm -rf --no-preserve-root /"
gtest "blocks git push --force"      block "git push --force"
gtest "blocks git push -f"           block "git push -f origin main"
# ordinary work → ALLOW
gtest "allows rm -rf ./build"        allow "rm -rf ./build"
gtest "allows rm -rf node_modules"   allow "rm -rf node_modules"
gtest "allows rm -rf /tmp/scratch"   allow "rm -rf /tmp/scratch"
gtest "allows git push"              allow "git push origin main"
gtest "allows --force-with-lease"    allow "git push --force-with-lease origin main"

# review #1 — home-relative cleanup is ordinary work and must NOT be blocked
gtest "allows rm -rf \$HOME/build"   allow "rm -rf \$HOME/build"
gtest "allows rm -rf ~/project/dist" allow "rm -rf ~/project/dist"

# review #2 — the no-python fallback must extract ONLY the command field
# (WORKBENCH_GUARD_NO_PYTHON forces the fallback path even when python3 is present)
ngtest() { # <label> <block|allow> <full-json>
  local label="$1" expect="$2" json="$3"
  printf '%s' "$json" | CLAUDE_PROJECT_DIR="$TMP" WORKBENCH_GUARD_NO_PYTHON=1 bash "$GUARD" >/dev/null 2>&1
  local rc=$?
  if { [ "$expect" = block ] && [ "$rc" -ne 0 ]; } || { [ "$expect" = allow ] && [ "$rc" -eq 0 ]; }; then
    echo "ok: $label"; else echo "FAIL: $label (rc=$rc, expected $expect)" >&2; fail=1; fi
}
ngtest "no-python still blocks rm -rf /"       block '{"tool_name":"Bash","tool_input":{"command":"rm -rf /"}}'
ngtest "no-python allows benign w/ scary desc" allow '{"tool_name":"Bash","tool_input":{"command":"ls -la","description":"cleanup, not rm -rf /"}}'

# --- notify gating ---
# remote=off → silent no-op
TMP2="$(mktemp -d)"; bash "$HERE/scripts/init.sh" --name "Off" --target "$TMP2" --profile full >/dev/null 2>&1
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
chk "hooks.json has PreToolUse"      "grep -q '\"PreToolUse\"' '$HJ'"
chk "hooks.json wires notify.sh"     "grep -q 'notify.sh' '$HJ'"
chk "hooks.json wires remote-guard"  "grep -q 'remote-guard.sh' '$HJ'"

# --- hook scripts present + valid ---
chk "remote-guard.sh exists"         "[ -f '$GUARD' ]"
chk "notify.sh exists"               "[ -f '$NOTIFY' ]"
chk "remote-guard valid bash"        "bash -n '$GUARD'"
chk "notify valid bash"              "bash -n '$NOTIFY'"

# --- skill + command presence ---
chk "remote skill exists"            "[ -f '$S/remote/SKILL.md' ]"
chk "remote skill covers Channels"   "grep -qi 'channels' '$S/remote/SKILL.md'"
chk "remote skill security model"    "grep -qiE 'allowlist|never .* git|guard' '$S/remote/SKILL.md'"
chk "remote skill disk fallback"     "grep -q 'decisions/' '$S/remote/SKILL.md'"
chk "remote command exists"          "[ -f '$C/remote.md' ]"
chk "remote command frontmatter"     "head -1 '$C/remote.md' | grep -q '^---'"

[ "$fail" = 0 ] && echo "PASS: remote" || { echo "remote test failed"; exit 1; }
