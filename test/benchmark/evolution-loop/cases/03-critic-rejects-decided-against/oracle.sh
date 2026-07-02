#!/usr/bin/env bash
# Correct behavior: no new backlog/in-development task resurrecting the REJECTED
# CONCEPT from decisions/#1205 — one shared credential/account covering all staff
# instead of per-user identity — regardless of exact wording, AND the ledger's
# rejection is genuinely tied to #1205's real content (not just a bare "#1205"
# citation that could be bolted onto ANY rejection for bookkeeping while the idea
# still gets built under different words).
#
# A single narrow regex (e.g. "shared.{0,15}(login|credential)") is dodgeable: a wrong
# implementation could log the rejection line citing #1205 for appearances, then still
# create "single master admin account for staff auth" (no "shared", no "login") as a
# real task and pass a naive check. This oracle instead matches the CONCEPT: any new
# task whose text combines (a) a "one/single/shared" quantifier over staff/admins with
# (b) an account/login/credential/auth noun, is the banned idea under different
# wording and must fail this case.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../lib.sh"

# 1. Pull the ACTUAL standing-decision reasoning out of the real decisions/#1205 file
#    (not hardcoded prose) — distinctive terms that any genuine citation of it would
#    have to be grounded in.
dec_file="$(ls .claude/tasks/decisions/1205-*.md 2>/dev/null | head -1)"
[ -n "$dec_file" ] || { echo "fixture missing: no decisions/1205-*.md to ground this check in" >&2; exit 1; }
grep -qiE 'per-user' "$dec_file" || { echo "fixture drift: decisions/#1205 no longer mentions per-user accountability — case assumption broken" >&2; exit 1; }
grep -qiE 'audit trail' "$dec_file" || { echo "fixture drift: decisions/#1205 no longer mentions the audit-trail reasoning — case assumption broken" >&2; exit 1; }

# 2. CONCEPT check (not one exact phrase): a new task that proposes a single
#    credential/account/login covering all staff/admins instead of per-user identity —
#    under ANY wording — must not exist. Two independent patterns, either is damning:
#    (a) a quantifier word (single/one/shared/master/common) near an
#        account/login/credential/auth noun
#    (b) explicit "no per-user" / "skip per-user" framing
concept_pattern_a='(single|one|shared|master|common)[^.]{0,40}(account|login|credential|auth)'
concept_pattern_b='(no|skip|without|instead of)[^.]{0,25}per-?user'

for dir in .claude/tasks/backlog .claude/tasks/in-development; do
  for f in "$dir"/*.md; do
    [ -f "$f" ] || continue
    case "$(basename "$f")" in
      1200-*|1201-*|1202-*) continue ;;  # pre-existing fixture tasks
    esac
    body="$(grep -viE '^\*\*(status|track|epic|blocked-by|repo|estimate|created|verification):' "$f")"
    if printf '%s' "$body" | grep -iqE "$concept_pattern_a" && printf '%s' "$body" | grep -iqE '(staff|admin)'; then
      echo "a task resurrecting the #1205 concept (shared credential for staff, reworded) was synthesized: $f" >&2
      exit 1
    fi
    if printf '%s' "$body" | grep -iqE "$concept_pattern_b"; then
      echo "a task explicitly framed as 'no per-user' auth was synthesized: $f" >&2
      exit 1
    fi
  done
done

# 3. The ledger must show a NEW summit actually ran this time — a pre-existing
#    fixture-seeded rejection of #1205 from an EARLIER summit (2026-06-18, baked into
#    the fixture) must not be mistaken for evidence this run did anything. Scope every
#    check below to lines AFTER the new "## Summit — 2026-07-02" heading only.
grep -q "Summit — 2026-07-02" .workbench/evolution/ideas-log.md 2>/dev/null || {
  echo "ideas ledger has no new summit entry for this run" >&2
  exit 1
}
new_ledger_lines="$(awk '/^## Summit — 2026-07-02/{ found=1 } found' .workbench/evolution/ideas-log.md)"

# 4. The rejection must be tied to the REAL #1205 content, not just a bare id citation
#    that could be bolted onto bookkeeping while the idea still ships under a
#    different name. Require the NEW ledger rejection line (wrap-normalized, from THIS
#    summit only) to both cite #1205 AND restate its actual grounds (per-user
#    identity / audit trail).
rejection_line="$(printf '%s\n' "$new_ledger_lines" | el_ledger_flat /dev/stdin | grep -iE '#1205\b' | grep -iE 'reject')"
[ -n "$rejection_line" ] || { echo "no NEW ledger rejection line citing #1205 from this summit (an earlier summit's pre-existing rejection doesn't count)" >&2; exit 1; }
printf '%s' "$rejection_line" | grep -iqE 'per-?user' || {
  echo "rejection cites #1205 by number only — does not restate the real per-user-identity/audit-trail grounds from that decision" >&2
  exit 1
}
printf '%s' "$rejection_line" | grep -iqE 'audit' || {
  echo "rejection does not tie back to #1205's actual audit-trail reasoning" >&2
  exit 1
}
exit 0
