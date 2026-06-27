#!/usr/bin/env bash
# Workbench adoption level detector (recommend-only). For a project being ADOPTED
# (no level chosen yet), reads git + repo signals and recommends a starting maturity
# level. Prints a machine-readable first line `recommended=<level>` followed by the
# human-readable signals. Always exits 0 — it advises; the human (or the setup wizard)
# decides. Pure bash, no jq/python.
#
# Usage: detect-level.sh [PROJECT_DIR]
set -uo pipefail
P="${1:-$PWD}"
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; . "$SELF/levels.sh"

# candidate level index (0=solo 1=pair 2=crew 3=fleet); we take the MAX across signals
idx=0
reasons=""
bump() { # <candidate_idx> <reason>
  [ "$1" -gt "$idx" ] && idx="$1"
  reasons="${reasons}  - $2"$'\n'
}

is_git=0; git -C "$P" rev-parse --git-dir >/dev/null 2>&1 && is_git=1

if [ "$is_git" = 1 ]; then
  # distinct commit-author emails = team size. (grep -c always prints a count, even 0,
  # and exits 1 on no matches — so NEVER append `|| echo 0`, which would yield "0\n0".)
  c="$(git -C "$P" log --format='%ae' 2>/dev/null | sort -u | grep -c . )"; c="${c:-0}"
  if   [ "${c:-0}" -ge 8 ]; then bump 3 "$c distinct committers → org-scale"
  elif [ "${c:-0}" -ge 4 ]; then bump 2 "$c distinct committers → team coordination"
  elif [ "${c:-0}" -ge 2 ]; then bump 1 "$c distinct committers → small-group alignment"
  fi

  # release tags = release discipline beyond push-to-main
  t="$(git -C "$P" tag 2>/dev/null | grep -c . )"; t="${t:-0}"
  if   [ "${t:-0}" -gt 10 ]; then bump 2 "$t release tags → tagged-release cadence"
  elif [ "${t:-0}" -ge 1 ];  then bump 1 "$t release tag(s) → some release discipline"
  fi

  # local branches beyond the trunk = feature-branch / parallel-stream workflow
  b="$(git -C "$P" for-each-ref --format='%(refname:short)' refs/heads 2>/dev/null \
        | grep -vcE '^(main|master)$' )"; b="${b:-0}"
  if   [ "${b:-0}" -gt 5 ]; then bump 2 "$b non-trunk branches → many parallel streams"
  elif [ "${b:-0}" -ge 1 ]; then bump 1 "$b non-trunk branch(es) → feature-branch workflow"
  fi
fi

# multiple repositories under repos/ = multi-repo coordination surface
r="$(ls -d "$P"/repos/*/ 2>/dev/null | grep -c . )"; r="${r:-0}"
if [ "${r:-0}" -gt 1 ]; then bump 2 "$r repositories under repos/ → multi-repo coordination"; fi

rec="$(wb_levels | tr ' ' '\n' | sed -n "$((idx+1))p")"; [ -n "$rec" ] || rec=solo

echo "recommended=$rec"
if [ "$is_git" = 0 ] && [ "${r:-0}" -le 1 ]; then
  echo "  - no git history and a single tree → starting at solo (you can graduate anytime)"
else
  printf '%s' "$reasons"
  [ -z "$reasons" ] && echo "  - quiet signals (single committer, trunk-only) → solo"
fi
exit 0
