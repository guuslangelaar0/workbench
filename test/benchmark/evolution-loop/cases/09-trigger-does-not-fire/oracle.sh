#!/usr/bin/env bash
# Correct behavior: neither trigger leg is true -> the ledger and backlog are BYTE-FOR-
# BYTE unchanged from the post-variant snapshot (no summit ran), verified by an actual
# content checksum/diff — not just file/line COUNTS, which a mutation that changes
# content while preserving counts (e.g. editing one existing line, or swapping one
# backlog file's body for another of the same length) would silently pass. The REAL
# `evolve.sh check` output (captured by simulate.sh) must also actually say "not-due",
# and the run output must explicitly say the trigger did not fire.
set -uo pipefail

# 1. Real trigger output was actually captured and is genuinely non-"due".
[ -f .evolve-check-output ] || { echo "no .evolve-check-output captured — evolve.sh check was not actually invoked" >&2; exit 1; }
check_line1="$(head -1 .evolve-check-output)"
case "$check_line1" in
  due*) echo "evolve.sh check's real output was '$check_line1' — the trigger DID fire; this case's fixture state should not trip either leg" >&2; exit 1 ;;
esac

# 2. Ledger content checksum — full-content sha256, not a line count.
snap_ledger_sha="$(cat .workbench/evolution/.snapshot-ledger-sha256 2>/dev/null || echo '')"
[ -n "$snap_ledger_sha" ] || { echo "no ledger checksum snapshot found — variant.sh did not run as expected" >&2; exit 1; }
now_ledger_sha="$(sha256sum .workbench/evolution/ideas-log.md 2>/dev/null | awk '{print $1}')"
[ "$now_ledger_sha" = "$snap_ledger_sha" ] || {
  echo "ideas ledger content changed (sha256 $snap_ledger_sha -> $now_ledger_sha) — the ledger was touched when the trigger should not have fired" >&2
  if [ -f .workbench/evolution/.snapshot-ledger-content ]; then
    diff -u .workbench/evolution/.snapshot-ledger-content .workbench/evolution/ideas-log.md >&2 || true
  fi
  exit 1
}

# 3. Backlog checksum — sha256 of every file's name+content, not just a count. This
#    catches a mutation that swaps a file's content but preserves file count.
snap_backlog_sha="$(cat .workbench/evolution/.snapshot-backlog-sha256 2>/dev/null || echo '')"
[ -n "$snap_backlog_sha" ] || { echo "no backlog checksum snapshot found — variant.sh did not run as expected" >&2; exit 1; }
now_backlog_sha="$({ for f in .claude/tasks/backlog/*.md; do [ -f "$f" ] || continue; sha256sum "$f"; done; } | sort -k2)"
[ "$now_backlog_sha" = "$snap_backlog_sha" ] || {
  echo "backlog/ content changed — a summit ran (or a file was mutated) when the trigger should not have fired" >&2
  echo "--- snapshot ---" >&2; printf '%s\n' "$snap_backlog_sha" >&2
  echo "--- now ---" >&2; printf '%s\n' "$now_backlog_sha" >&2
  exit 1
}

grep -qiE "doesn't fire|does not fire|no summit|not (yet )?due|trigger.{0,15}(not|doesn't|does not)" "$RUN_OUTPUT" 2>/dev/null || {
  echo "run output doesn't explicitly say the trigger did not fire" >&2
  exit 1
}
exit 0
