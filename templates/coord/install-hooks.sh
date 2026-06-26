#!/usr/bin/env bash
# install-hooks — wire the commit guard (B) into a repo's pre-commit hook.
#
#   scripts/coord/install-hooks.sh            # workspace root repo
#   scripts/coord/install-hooks.sh --all      # root + every repos/* git repo
#   scripts/coord/install-hooks.sh <repo-dir>
#
# Idempotent: appends a marked block that calls precommit-guard.sh. Preserves
# any existing hook (check-secrets, check-shared-sync, …) — the guard is added
# as an additional gate, not a replacement.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/lib.sh"

MARKER="# >>> wb-coord commit guard (B) >>>"

install_one() {
  local top; top="$(git -C "$1" rev-parse --show-toplevel 2>/dev/null || true)"
  [ -z "$top" ] && { echo "skip (not a git repo): $1"; return; }
  local hookdir; hookdir="$(git -C "$top" rev-parse --absolute-git-dir)/hooks"
  local hook="$hookdir/pre-commit"
  mkdir -p "$hookdir"
  if [ -f "$hook" ] && grep -qF "$MARKER" "$hook"; then
    echo "already installed: ${top#"$WB_ROOT"/}"
    return
  fi
  # path to the guard relative to nothing — use absolute so it works from any worktree
  local guard="$DIR/precommit-guard.sh"
  if [ ! -f "$hook" ]; then
    printf '#!/usr/bin/env bash\nset -euo pipefail\n' > "$hook"
  fi
  {
    printf '\n%s\n' "$MARKER"
    printf '"%s" || exit 1\n' "$guard"
    printf '# <<< wb-coord commit guard (B) <<<\n'
  } >> "$hook"
  chmod +x "$hook"
  echo "installed: ${top#"$WB_ROOT"/}  ($hook)"
}

case "${1:-}" in
  --all)
    install_one "$WB_ROOT"
    for r in "$WB_ROOT"/repos/*/; do [ -d "$r/.git" ] && install_one "$r"; done
    ;;
  "" ) install_one "$WB_ROOT" ;;
  * )  install_one "$1" ;;
esac
