#!/usr/bin/env bash
# workbench ANTI-GAMING / reward-hacking guard. The verification contract proves
# evidence EXISTS; it cannot prove the evidence wasn't FAKED. This inspects a code
# diff for the classic ways a loop games its own gate to mark work "done":
#   • a test file deleted                          (hard)
#   • a test disabled/skipped/ignored ADDED        (hard)
#   • a trivially-passing assertion ADDED          (hard)
#   • net assertions removed                       (soft)
# It is a HEURISTIC that raises honest suspicion — it does NOT certify. Language-aware
# (rust / js-ts / python / go / java / swift), pure bash + awk, and FAILS OPEN.
#
# Per the design's open decision: a HARD signal blocks only when the level enforces
# (crew/fleet) AND the task claims its tests pass (the unambiguous "deleted a test
# while saying tests pass" case). Everything else is advisory + a `warn` suggestion.
#
# Diff source (first that resolves): --diff FILE | --range GITREF | working tree (git diff HEAD).
# Usage: gate-integrity.sh [--diff FILE | --range REF] [--task FILE] [--key K] [--target DIR] [--strict]
# Exit:  0 clean OR advisory OR fail-open · 3 block (hard + enforce + pass-claim, or --strict) · 64 usage
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SELF_DIR/lib.sh"

DIFF_FILE="" RANGE="" TASK="" KEY="" TARGET="$PWD" STRICT=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --diff)   DIFF_FILE="$2"; shift 2 ;;
    --range)  RANGE="$2"; shift 2 ;;
    --task)   TASK="$2"; shift 2 ;;
    --key)    KEY="$2"; shift 2 ;;
    --target) TARGET="$2"; shift 2 ;;
    --strict) STRICT=1; shift ;;
    -*) echo "gate-integrity.sh: unknown flag '$1'" >&2; exit 64 ;;
    *)  echo "gate-integrity.sh: unexpected arg '$1'" >&2; exit 64 ;;
  esac
done
TARGET="${TARGET%/}"; [ -n "$TARGET" ] || TARGET="/"

# --- resolve the diff text (fail open to empty)
D=""
if [ -n "$DIFF_FILE" ]; then
  [ -f "$DIFF_FILE" ] && D="$(cat "$DIFF_FILE")"
elif [ -n "$RANGE" ]; then
  D="$(git -C "$TARGET" diff "$RANGE" 2>/dev/null || true)"
else
  D="$(git -C "$TARGET" diff HEAD 2>/dev/null || true)"
fi
[ -n "$D" ] || { echo "gate-integrity: SKIP (empty diff — nothing to inspect)"; exit 0; }

# test-file path heuristic
_is_testpath() { printf '%s' "$1" | grep -qiE '(^|/)(tests?|specs?|__tests__)/|(\.|_)(test|spec)\.[A-Za-z]+$|(^|/)test_[^/]*\.py$|_test\.go$'; }

# added (+) / removed (-) payload lines, excluding the ---/+++ file headers
added="$(printf '%s\n' "$D"   | grep -E '^\+' | grep -vE '^\+\+\+')"
removed="$(printf '%s\n' "$D" | grep -E '^-'  | grep -vE '^---')"

# --- HARD: test files deleted (parse `diff --git` path + `deleted file mode`)
deleted_tests="$(printf '%s\n' "$D" | awk '
  /^diff --git / { path=$3; sub(/^a\//,"",path); next }
  /^deleted file mode/ { if (path!="") print path; path="" }
')"
del_test_hits=""
while IFS= read -r p; do
  [ -n "$p" ] || continue
  if _is_testpath "$p"; then del_test_hits="${del_test_hits:+$del_test_hits, }$p"; fi
done <<< "$deleted_tests"

# --- HARD: a test disabled / skipped / ignored, ADDED
skip_re='#\[ignore\]|\bit\.skip\(|\bdescribe\.skip\(|\bxit\(|\bxdescribe\(|\btest\.skip\(|\.skip\(|@pytest\.mark\.skip|@(Disabled|Ignore)\b|\bt\.Skip\(|\bt\.SkipNow\('
skip_hits="$(printf '%s\n' "$added" | grep -nE "$skip_re" | head -5 || true)"

# --- HARD: trivially-passing assertion, ADDED
trivial_re='assert[[:space:]]+True\b|assert[[:space:]]*\([[:space:]]*[Tt]rue[[:space:]]*\)|assert!\([[:space:]]*true|expect\([[:space:]]*true[[:space:]]*\)|assertTrue\([[:space:]]*true|XCTAssertTrue\([[:space:]]*true|assert[[:space:]]+1[[:space:]]*==[[:space:]]*1|assertEquals\([[:space:]]*(true|1)[[:space:]]*,[[:space:]]*(true|1)'
trivial_hits="$(printf '%s\n' "$added" | grep -nE "$trivial_re" | head -5 || true)"

# --- SOFT: net assertions removed (added vs removed assert-ish lines)
assertish='\bassert|\bexpect\(|\bEXPECT|\bASSERT|XCTAssert|#\[test\]|\bit\(|\btest\(|def[[:space:]]+test_'
n_add="$(printf '%s\n' "$added"   | grep -cE "$assertish" || true)"
n_rem="$(printf '%s\n' "$removed" | grep -cE "$assertish" || true)"
net_drop=$(( n_rem - n_add )); [ "$net_drop" -lt 0 ] && net_drop=0

# --- assemble findings
hard="" soft=""
[ -n "$del_test_hits" ] && hard="${hard}test file(s) deleted: ${del_test_hits}; "
[ -n "$skip_hits" ]     && hard="${hard}test(s) skipped/ignored added; "
[ -n "$trivial_hits" ]  && hard="${hard}trivially-passing assertion(s) added; "
[ "$net_drop" -gt 0 ]   && soft="${soft}${net_drop} net assertion line(s) removed; "

if [ -z "$hard$soft" ]; then echo "gate-integrity: clean — no gaming signals in the diff"; exit 0; fi

# --- pass-claim in the task file? (the discriminator for blocking)
claims_pass=0
if [ -n "$TASK" ] && [ -f "$TASK" ]; then
  grep -qiE '(tests?|suite|ci|build)[^.]{0,40}(pass|passing|passed|green|ok\b)|all[[:space:]]+tests|✓|✅' "$TASK" && claims_pass=1
fi

# --- level posture
enforce=0 level=""
_cfg="$(il_cfg_dir "$TARGET")/config.json"
if [ -f "$_cfg" ]; then
  level="$(sed -n 's/.*"level"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$_cfg" | head -1)"
  case "$level" in crew|fleet) enforce=1 ;; esac
fi

# --- file a warn suggestion (recommend-only surface), deduped by key
if [ -x "$SELF_DIR/suggest.sh" ]; then
  k="${KEY:-gaming-$(printf '%s' "$hard$soft" | il_hash /dev/stdin 2>/dev/null | cut -c1-8)}"
  [ -n "$k" ] || k="gaming-unknown"
  bash "$SELF_DIR/suggest.sh" add --key "$k" --severity warn \
    --title "Possible verification gaming in the diff" \
    --why "${hard}${soft}" \
    --how "review the diff; if legitimate (e.g. obsolete test removed), dismiss; else bounce the task to in-development" \
    --source gate-integrity --target "$TARGET" >/dev/null 2>&1 || true
fi

# metric: a hard signal is a gaming attempt worth scoring against the loop
if [ -n "$hard" ] && [ -x "$SELF_DIR/metric.sh" ]; then
  "$SELF_DIR/metric.sh" emit gaming_flag --detail "$hard" --target "$TARGET" >/dev/null 2>&1 || true
fi

echo "gate-integrity: SUSPICIOUS (heuristic — review, do not treat as proof)" >&2
[ -n "$hard" ] && echo "  hard: $hard" >&2
[ -n "$soft" ] && echo "  soft: $soft" >&2

# --- block decision
if [ "$STRICT" = 1 ] && [ -n "$hard" ]; then
  echo "  BLOCK (--strict + hard signal)" >&2; exit 3
fi
if [ "$enforce" = 1 ] && [ -n "$hard" ] && [ "$claims_pass" = 1 ]; then
  echo "  BLOCK — a test was weakened while the task claims tests pass (level '$level' enforces)" >&2; exit 3
fi
echo "  ADVISORY (filed a suggestion; not blocking)" >&2
exit 0
