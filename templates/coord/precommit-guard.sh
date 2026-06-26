#!/usr/bin/env bash
# precommit-guard — prevent one session's commit from sweeping another
# session's staged files in a SHARED git repo (B).
#
# Wired into a repo's .git/hooks/pre-commit (see install-hooks.sh). It:
#   1. refreshes this session's presence heartbeat (keeps `bb-coord who` honest)
#   2. when ALL of these hold:
#        - another LIVE session has uncommitted changes in THIS repo, AND
#        - this is a BULK commit (committing the entire index, not a pathspec)
#      it emits a heads-up. DEFAULT = warn-only (commit still proceeds, so the
#      other tabs keep working); BB_COORD_STRICT=1 makes it hard-BLOCK instead.
#
# Rationale: a scoped commit (`git commit -- <paths>`) can only ever commit the
# paths you name, so it cannot sweep a sibling session's staged files. A bulk
# commit while a sibling is active is the exact footgun we hit. Worktrees
# (scripts/coord/bb-worktree.sh) avoid this entirely; this guards the shared
# workspace-root repo where worktrees are impractical.
#
# Env knobs:
#   BB_COORD_STRICT=1   hard-block bulk commits (default is warn-only)
#   BB_COMMIT_FORCE=1   proceed despite the warning/block (you accept the risk)
#   BB_COORD_DISABLE=1  disable the guard entirely
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$DIR/lib.sh"

[ -n "${BB_COORD_DISABLE:-}" ] && exit 0

sid="$(bb_sid)"
repo_top="$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")"
repo_label="workspace"; [ "$repo_top" != "$BB_ROOT" ] && repo_label="${repo_top#"$BB_ROOT"/}"

# 1) refresh our own presence (best-effort, never block the commit on this)
"$DIR/bb-coord" ping "${BB_LABEL:-commit}" >/dev/null 2>&1 || true

# 2) are other live sessions active in THIS repo with uncommitted changes?
others=0; names=""
if [ -d "$BB_SESSIONS_DIR" ]; then
  for f in "$BB_SESSIONS_DIR"/*.json; do
    [ -e "$f" ] || continue
    s="$(bb_json_get "$f" sid || true)"; [ "$s" = "$sid" ] && continue
    hb="$(bb_json_get "$f" heartbeat_epoch || echo 0)"
    bb_is_fresh "$hb" "$BB_SESSION_TTL" || continue
    r="$(bb_json_get "$f" repo || echo -)"; [ "$r" = "$repo_label" ] || continue
    st="$(bb_json_get "$f" staged || echo 0)"; dy="$(bb_json_get "$f" dirty || echo 0)"
    if [ "${st:-0}" -gt 0 ] 2>/dev/null || [ "${dy:-0}" -gt 0 ] 2>/dev/null; then
      others=$((others+1)); names="${names:+$names, }$(bb_sid_short "$s")${r:+}"
    fi
  done
fi
[ "$others" -eq 0 ] && exit 0   # solo in this repo → nothing to protect against

# 3) bulk vs scoped: compare what's being committed to the FULL real index.
#    A scoped (`-- pathspec`) commit narrows the committed set below the real
#    index; a bulk commit commits the whole index.
committed="$(git diff --cached --name-only 2>/dev/null | sort)"
real_index="$(GIT_INDEX_FILE="$repo_top/.git/index" git diff --cached --name-only 2>/dev/null | sort)"
committed_n="$(printf '%s' "$committed" | grep -c . || true)"
real_n="$(printf '%s' "$real_index" | grep -c . || true)"

if [ "$committed_n" -lt "$real_n" ]; then
  exit 0   # scoped commit — cannot sweep foreign staged files
fi

# FORCE always proceeds silently-ish (only meaningful in strict mode).
[ -n "${BB_COMMIT_FORCE:-}" ] && { echo "${BB_YEL}coord: BB_COMMIT_FORCE set — proceeding despite $others active session(s).${BB_RST}" >&2; exit 0; }

# Default is WARN-ONLY: print a heads-up but let the commit proceed, so parallel
# sessions keep working. Set BB_COORD_STRICT=1 to hard-block bulk commits instead.
strict=""; [ -n "${BB_COORD_STRICT:-}" ] && strict=1
if [ -n "$strict" ]; then
  hdr="${BB_RED}${BB_BOLD}✗ Commit blocked by coord (strict):${BB_RST}"; fate="blocked."
else
  hdr="${BB_YEL}${BB_BOLD}⚠ coord heads-up:${BB_RST}"; fate="proceeding anyway (warn-only)."
fi

cat >&2 <<EOF
$hdr ${others} other live session(s) have uncommitted changes in '${repo_label}': ${names}
  This is a BULK commit (whole index) — it could sweep their staged files. $fate
  • commit only your files:   ${BB_BOLD}git commit -- <path> [<path>...]${BB_RST}
  • see who's active:         ${BB_BOLD}scripts/coord/bb-coord status${BB_RST}
  • isolate:                  ${BB_BOLD}scripts/coord/bb-worktree.sh new <name>${BB_RST}
EOF
if [ -n "$strict" ]; then
  echo "  • override (accept risk):   ${BB_BOLD}BB_COMMIT_FORCE=1 git commit ...${BB_RST}" >&2
  exit 1
fi
exit 0
