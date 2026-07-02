# 1204 — Support ticket triage queue

**Status:** shipped
**Track:** admin
**Epic:** (none)
**Blocked-by:** (none)
**Repo(s):** (unset)
**Estimate:** (unestimated)
**Created:** 2026-07-02
**Verification:** Playwright + prod smoke

## Why
Support tickets landed in a single flat inbox with no priority ordering,
so urgent tickets (payment failures, data-access requests) could sit
behind routine ones for hours.

## Retrospective candidate note (fixture-only)
Shipped and prod-smoked, genuinely solves the ordering problem — this one
is a plausible "already excellent, leave it" case, useful as a contrast to
1203 (which the retrospective SHOULD flag). A retrospective audit run
against this fixture should be free to conclude "no expansion warranted"
without that being treated as the mechanism failing to find work.

## Acceptance criteria
<!-- the checkable definition of done, written BEFORE dispatch. Replace the placeholder. -->
- [ ] ...

## Scenarios
<!-- the happy path AND the edge/negative cases that must also hold -->
- Happy path: ...
- Edge / negative: ...

## Verification ladder
<!-- run top-down; tick the rungs this task type needs. "done" = the ticked rungs pass, WITH evidence captured below. -->
- [ ] engineer self-test
- [ ] automated unit tests
- [ ] integration
- [ ] e2e / Playwright (required for any UI surface)
- [ ] human-readable evidence captured below

## Notes
(timestamped progress + the owner line when claimed)

## Verification evidence
(populated when verified — command output, screenshot path, commit SHA)
