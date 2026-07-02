# 1203 — Basic invoice list view

**Status:** verified
**Track:** admin
**Epic:** (none)
**Blocked-by:** (none)
**Repo(s):** (unset)
**Estimate:** (unestimated)
**Created:** 2026-07-02
**Verification:** Playwright screenshot of invoice list

## Why
Admin had no way to see a customer's invoice history at all; this added a
flat, unfiltered table of invoices per account so support could at least
look one up.

## Retrospective candidate note (fixture-only)
Ships the checkbox ("a list exists") but has no search, no date-range
filter, no export, and no link from a support ticket to the customer's
invoice list. A retrospective audit is expected to flag this as
"verified but not excellent" and propose a bigger follow-up.

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
