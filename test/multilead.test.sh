#!/usr/bin/env bash
# Multi-teamlead + coordination: behavioral (bb-coord claims query, locks gitignore)
# + presence (coordination skill, /teamlead command, dispatch claim wiring).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # tools/initlab
S="$HERE/skills"; C="$HERE/commands"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail=0
chk() { if eval "$2"; then echo "ok: $1"; else echo "FAIL: $1" >&2; fail=1; fi; }

# scaffold a full project (gives scripts/coord/bb-coord + .initlab/config.json)
bash "$HERE/scripts/init.sh" --name "Acme" --mission "Test." --target "$TMP" --profile full >/dev/null 2>&1
BBC="$TMP/scripts/coord/bb-coord"

# --- gitignore: coordination runtime state must be ignored (and not duplicated on re-run) ---
chk "scaffold gitignores .claude/locks/"   "grep -qxF '/.claude/locks/' '$TMP/.gitignore'"
bash "$HERE/scripts/init.sh" --name "Acme" --mission "Test." --target "$TMP" --profile full >/dev/null 2>&1
chk "gitignore locks line not duplicated"  "[ \"\$(grep -cxF '/.claude/locks/' '$TMP/.gitignore')\" = 1 ]"

# --- bb-coord claims: cross-session visibility ---
export BB_WORKSPACE_ROOT="$TMP"
BB_SID_OVERRIDE=sessAstorage bash "$BBC" ping "lead:storage" >/dev/null 2>&1
BB_SID_OVERRIDE=sessAstorage bash "$BBC" claim "task:0042" >/dev/null 2>&1
BB_SID_OVERRIDE=sessBmobile  bash "$BBC" ping "lead:mobile"  >/dev/null 2>&1

out="$(BB_SID_OVERRIDE=sessBmobile bash "$BBC" claims task:0042 2>/dev/null)"
chk "another session sees the claim (text)"  "printf '%s' \"\$out\" | grep -q 'task:0042'"
chk "claims query exits 0 when claimed"      "BB_SID_OVERRIDE=sessBmobile bash '$BBC' claims task:0042 >/dev/null 2>&1"
chk "claims query exits 1 when free"         "! BB_SID_OVERRIDE=sessBmobile bash '$BBC' claims task:9999 >/dev/null 2>&1"
chk "claims query ignores own claim"         "! BB_SID_OVERRIDE=sessAstorage bash '$BBC' claims task:0042 >/dev/null 2>&1"

st="$(BB_SID_OVERRIDE=sessBmobile bash "$BBC" status 2>/dev/null)"
chk "status surfaces a Claims section"       "printf '%s' \"\$st\" | grep -qi 'claim'"
chk "status shows the claimed key"           "printf '%s' \"\$st\" | grep -q 'task:0042'"

# de-dup: claiming the same key twice does not grow the stored list
BB_SID_OVERRIDE=sessAstorage bash "$BBC" claim "task:0042" >/dev/null 2>&1
dups="$(grep -o 'task:0042' "$TMP/.claude/locks/sessions/sessAstorage.json" | grep -c . || true)"
chk "claim de-dups (key stored once)"        "[ \"\$dups\" = 1 ]"

# robustness: claim must truthfully succeed even if the session file predates the
# claims field (older ping format) — insert the field, never false-report success.
printf '{"sid":"sessOld","heartbeat_epoch":%s,"label":"x"}\n' "$(date +%s)" > "$TMP/.claude/locks/sessions/sessOld.json"
BB_SID_OVERRIDE=sessOld bash "$BBC" claim "task:0050" >/dev/null 2>&1
chk "claim inserts claims field when absent" "grep -q '\"claims\":\"task:0050\"' '$TMP/.claude/locks/sessions/sessOld.json'"
chk "another session sees the inserted claim" "BB_SID_OVERRIDE=sessXother bash '$BBC' claims task:0050 >/dev/null 2>&1"
unset BB_WORKSPACE_ROOT

# --- presence: coordination skill ---
chk "coordination skill exists"          "[ -f '$S/coordination/SKILL.md' ]"
chk "coordination covers bb-coord"       "grep -q 'bb-coord' '$S/coordination/SKILL.md'"
chk "coordination covers worktrees"      "grep -qi 'worktree' '$S/coordination/SKILL.md'"
chk "coordination covers with-lock"      "grep -q 'with-lock' '$S/coordination/SKILL.md'"
chk "coordination covers claims/locking" "grep -q 'claim' '$S/coordination/SKILL.md'"
chk "coordination covers overlap/pathspec" "grep -qiE 'overlap|pathspec' '$S/coordination/SKILL.md'"
chk "coordination notes gitignored state" "grep -qi 'gitignore' '$S/coordination/SKILL.md'"

# --- presence: /teamlead command ---
chk "teamlead command exists"            "[ -f '$C/teamlead.md' ]"
chk "teamlead has frontmatter"           "head -1 '$C/teamlead.md' | grep -q '^---'"
chk "teamlead sets lead: label"          "grep -q 'lead:' '$C/teamlead.md'"
chk "teamlead scopes by Track"           "grep -q 'Track' '$C/teamlead.md'"
chk "teamlead pings coord"               "grep -q 'bb-coord' '$C/teamlead.md'"

# --- presence: dispatch now claims; orchestration composes coordination ---
chk "dispatch claims the task"           "grep -q 'bb-coord' '$C/dispatch.md' && grep -q 'claim' '$C/dispatch.md'"
chk "orchestration references coordination" "grep -qi 'coordination' '$S/orchestration/SKILL.md'"

[ "$fail" = 0 ] && echo "PASS: multilead" || { echo "multilead test failed"; exit 1; }
