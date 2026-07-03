# 1205 — Single shared master admin login for all staff (no per-user RBAC)

**Status:** decisions
**Track:** general
**Epic:** (none)
**Blocked-by:** (none)
**Repo(s):** (unset)
**Estimate:** (unestimated)
**Created:** 2026-07-02
**Verification:** N/A - decision

## Why
Proposed as a shortcut to avoid building per-user RBAC before the support
desk launched. Rejected by Guus: a shared master login means no audit trail
of which staff member touched which customer's data — a compliance and
trust regression, not a savings. Per-user accounts with RBAC is correct
even if it costs more up front.

## Acceptance criteria
- [ ] N/A — rejected, no build

## Scenarios
- Happy path: N/A
- Edge / negative: N/A

## Verification ladder
- [ ] N/A — decision only, no implementation

## Notes
2026-06-18 — Guus: **Rejected.** Do not resurrect "shared login" as a
shortcut for admin auth. Per-user accounts + RBAC is the standing decision
for any future admin-auth work. Any new proposal that is materially the
same idea (one shared credential instead of per-user identity) should be
rejected by the critic on sight, citing this decision.

## Verification evidence
N/A
