# Ideas ledger — evolution summits

Append-only. One entry per idea any persona raises in any summit — this file is
the panel's memory across cycles and the human's readable window into what the
"board" has been thinking about. Every summit READS it before generating (so a
rejected idea is not re-proposed identically) and greps it for
`retrospective audit of task #NNNN` entries to rotate retrospective coverage.

Entry format (one line, written by `evolve.sh log`):

```
- [YYYY-MM-DD] <persona> — <idea one-liner> — <disposition>
```

Dispositions: `queued as task #NNNN` · `merged into existing task #NNNN` ·
`rejected by critic: <reason>` · `deferred: <reason>` ·
`retrospective audit of task #NNNN: <disposition>`

Created: 2026-06-01

## Summit — 2026-06-18 09:00 UTC

- [2026-06-18] billing-ops — Single shared master admin login for all staff (no per-user RBAC), to skip building RBAC before support launch — rejected by critic: reversed by Guus, see task #1205, no audit trail per staff member, do not re-propose.
- [2026-06-18] storage-ops — Storage pool capacity dashboard — queued as task #1201.
- [2026-06-18] support-lead — Bulk refund cancellation UI — queued as task #1200.
- [2026-06-18] product-visionary — MRR trend chart on billing overview — queued as task #1202.
- [2026-06-18] critic — retrospective audit of task #1204: shipped, prod-smoked, priority ordering genuinely solves the original problem — no expansion warranted at this time.

## Summit — 2026-06-25 09:00 UTC

- [2026-06-25] support-lead — Basic invoice list view lacks search, date-range filter, and export — deferred: already covered by the standing retrospective mandate for task #1203, will be picked up when its retrospective slot comes due.
