#!/usr/bin/env bash
# workbench PreToolUse safety guard. When remote control is enabled (remote != off),
# hard-block (exit 2) a narrow set of catastrophic, irreversible commands so a
# remote-driven (e.g. Telegram) command can't destroy the machine without explicit
# local approval — this overrides bypass / auto-approve mode. No-ops unless this is
# a workbench project with remote != off. Precise with python3; raw-scan fallback
# without. Fails OPEN (never blocks ordinary work) on any uncertainty.
#
# Scope (deliberately narrow, to avoid false positives): `rm -rf` of /, /*, ~, ~/,
# $HOME or with --no-preserve-root; and `git push --force`/`-f` (the safe
# --force-with-lease is allowed). It is a safety net, not a complete sandbox.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SELF_DIR/../../scripts/lib.sh"
P="${CLAUDE_PROJECT_DIR:-$PWD}"
_cfg="$(il_cfg_dir "$P")/config.json"
[ -f "$_cfg" ] || exit 0
remote="$(sed -n 's/.*"remote"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$_cfg" | head -1)"
[ -n "$remote" ] && [ "$remote" != off ] || exit 0

input="$(cat)"
cmd=""
if [ -z "${WORKBENCH_GUARD_NO_PYTHON:-}" ] && command -v python3 >/dev/null 2>&1; then
  cmd="$(printf '%s' "$input" | python3 -c 'import json,sys
try:
    print(json.load(sys.stdin).get("tool_input",{}).get("command",""))
except Exception:
    pass' 2>/dev/null || true)"
fi
# fallback (no python3, or it failed): best-effort extract ONLY the command field —
# never scan the whole payload, or a benign command's description naming a dangerous
# one would false-block (and a trailing JSON quote would hide a real one).
[ -n "$cmd" ] || cmd="$(printf '%s' "$input" | sed -n 's/.*"command"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
scan="$cmd"   # the command only; empty (unparseable) → no pattern matches → fails open

block() { echo "workbench remote-guard: blocked — $1. If truly intended, run it locally with explicit approval (this guard protects remote-driven sessions)." >&2; exit 2; }

# rm -rf / -fr targeting the ROOT (/ or /*) — a trailing slash still counts (// == /).
rm_root_rf='rm[[:space:]]+-[a-z]*r[a-z]*f[a-z]*[[:space:]]+(--[a-z-]+[[:space:]]+)*(/|/\*)([[:space:]/]|$)'
rm_root_fr='rm[[:space:]]+-[a-z]*f[a-z]*r[a-z]*[[:space:]]+(--[a-z-]+[[:space:]]+)*(/|/\*)([[:space:]/]|$)'
# rm -rf / -fr targeting HOME itself (~, ~/, $HOME) as a WHOLE word, NOT a subpath —
# so `rm -rf ~/project` and `rm -rf $HOME/build` are ordinary cleanup and allowed.
rm_home_rf='rm[[:space:]]+-[a-z]*r[a-z]*f[a-z]*[[:space:]]+(--[a-z-]+[[:space:]]+)*(~|~/|\$\{?home\}?)([[:space:]]|$)'
rm_home_fr='rm[[:space:]]+-[a-z]*f[a-z]*r[a-z]*[[:space:]]+(--[a-z-]+[[:space:]]+)*(~|~/|\$\{?home\}?)([[:space:]]|$)'
if printf '%s' "$scan" | grep -Eiq "$rm_root_rf" \
   || printf '%s' "$scan" | grep -Eiq "$rm_root_fr" \
   || printf '%s' "$scan" | grep -Eiq "$rm_home_rf" \
   || printf '%s' "$scan" | grep -Eiq "$rm_home_fr" \
   || printf '%s' "$scan" | grep -Eiq 'rm[[:space:]].*--no-preserve-root'; then
  block "catastrophic 'rm' on a root/home path"
fi

# force-push (allow the safe --force-with-lease)
if printf '%s' "$scan" | grep -Eq 'git[[:space:]]+push'; then
  if printf '%s' "$scan" | grep -Eq -- '--force-with-lease'; then
    :   # safe form — allow
  elif printf '%s' "$scan" | grep -Eq -- '(--force([[:space:]]|=|$)|[[:space:]]-f([[:space:]]|$))'; then
    block "'git push --force' (use --force-with-lease locally instead)"
  fi
fi

exit 0
