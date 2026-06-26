#!/usr/bin/env bash
# bb-worktree — per-session git worktrees (A).
#
# The cleanest collision fix: give each tab its own worktree + branch, so its
# index and HEAD are fully independent. One session's commit can never touch
# another's staging area. Use this for focused code work in a single repo.
#
#   bb-worktree.sh new <name> [repo-dir]   create + cd hint
#   bb-worktree.sh list [repo-dir]
#   bb-worktree.sh rm <name> [repo-dir]
#
# Worktrees live under <repo>/.claude/worktrees/<name> on branch wt/<name>
# (matches the existing repos/*/.claude/worktrees pattern).
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$DIR/lib.sh"

sub="${1:-list}"; shift || true

repo_dir() { git -C "${1:-$PWD}" rev-parse --show-toplevel 2>/dev/null || { echo "not in a git repo" >&2; exit 1; }; }

case "$sub" in
  new)
    name="${1:?usage: bb-worktree.sh new <name> [repo-dir]}"
    top="$(repo_dir "${2:-$PWD}")"
    wt="$top/.claude/worktrees/$name"; br="wt/$name"
    mkdir -p "$top/.claude/worktrees"
    if git -C "$top" show-ref --verify --quiet "refs/heads/$br"; then
      git -C "$top" worktree add "$wt" "$br"
    else
      git -C "$top" worktree add -b "$br" "$wt"
    fi
    echo ""
    echo "${WB_GRN}● worktree ready${WB_RST}  branch ${WB_BOLD}$br${WB_RST}"
    echo "  cd $wt"
    echo "  (work here; commits stay on '$br' and never collide with other tabs)"
    echo "  merge later:  git -C $top merge $br   (or open a PR)"
    ;;
  list)
    top="$(repo_dir "${1:-$PWD}")"
    git -C "$top" worktree list
    ;;
  rm|remove)
    name="${1:?usage: bb-worktree.sh rm <name> [repo-dir]}"
    top="$(repo_dir "${2:-$PWD}")"
    git -C "$top" worktree remove "$top/.claude/worktrees/$name" && echo "removed worktree $name (branch wt/$name kept)"
    ;;
  *) echo "usage: bb-worktree.sh {new|list|rm} ..." >&2; exit 64 ;;
esac
