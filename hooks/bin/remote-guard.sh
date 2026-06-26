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
# fallback (no python3, or it failed): best-effort extract ONLY the FIRST command
# field — never scan the whole payload, or a benign command's description naming a
# dangerous one would false-block. grep -o + head -1 takes the first occurrence so a
# second decoy "command" key downstream can't hide the real one.
[ -n "$cmd" ] || cmd="$(printf '%s' "$input" | grep -oE '"command"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed -E 's/.*:[[:space:]]*"([^"]*)"/\1/')"
scan="$cmd"   # the command only; empty (unparseable) → no pattern matches → fails open

block() { echo "workbench remote-guard: blocked — $1. If truly intended, run it locally with explicit approval (this guard protects remote-driven sessions)." >&2; exit 2; }

# Recursive + force `rm` on a top-level dangerous target, in ANY flag arrangement:
# -rf, -fr, -r -f, -Rf, --recursive --force, or split/combined short clusters (-xrf).
# The recursive and force flags are matched INDEPENDENTLY so order/joining doesn't
# matter. Subpaths (~/project, $HOME/build, /usr) are ordinary cleanup and allowed;
# only the bare root/home (/, /*, ~, ~/, $HOME, $HOME/, $HOME/*) trips the target.
rm_recursive='(^|[[:space:]])(-[a-z]*r[a-z]*|--recursive)([[:space:]]|$)'
rm_force='(^|[[:space:]])(-[a-z]*f[a-z]*|--force)([[:space:]]|$)'
danger_target='(^|[[:space:]])(/|/\*|~|~/|\$\{?[Hh][Oo][Mm][Ee]\}?/?\*?)([[:space:]]|$)'
if printf '%s' "$scan" | grep -Eq '(^|[;&|[:space:]])rm([[:space:]]|$)'; then
  # --no-preserve-root exists only to defeat rm's built-in / protection → block outright
  if printf '%s' "$scan" | grep -Eq -- '--no-preserve-root'; then
    block "catastrophic 'rm --no-preserve-root'"
  fi
  if printf '%s' "$scan" | grep -Eiq "$rm_recursive" \
     && printf '%s' "$scan" | grep -Eiq "$rm_force" \
     && printf '%s' "$scan" | grep -Eq "$danger_target"; then
    block "catastrophic recursive 'rm' on a root/home path"
  fi
fi

# force-push. The safe --force-with-lease (alone) is allowed; a plain --force or any
# short flag cluster containing f (-f, -xf, --force-with-lease --force) is blocked.
# `--force([[:space:]]|=|$)` does NOT match the substring inside --force-with-lease
# (followed by '-'), so the lease form passes while a co-present plain --force trips.
if printf '%s' "$scan" | grep -Eq '(^|[[:space:]])git[[:space:]]+push'; then
  if printf '%s' "$scan" | grep -Eq -- '--force([[:space:]]|=|$)' \
     || printf '%s' "$scan" | grep -Eq '(^|[[:space:]])-[a-z]*f[a-z]*([[:space:]]|$)'; then
    block "'git push --force' (use --force-with-lease locally instead)"
  fi
fi

exit 0
