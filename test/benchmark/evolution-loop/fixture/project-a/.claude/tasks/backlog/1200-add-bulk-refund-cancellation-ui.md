# 1200 — Add bulk refund cancellation UI

**Status:** backlog
**Track:** admin
**Epic:** (none)
**Blocked-by:** (none)
**Repo(s):** (unset)
**Estimate:** (unestimated)
**Created:** 2026-07-02
**Verification:** Playwright screenshot of the flow

## Why
Support currently has to cancel refunds one at a time via individual API
calls; when a batch of refunds was issued in error (e.g. a Stripe webhook
storm double-refunded a cohort), there is no bulk-cancel path in the admin
UI, forcing a slow manual loop under time pressure.

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
