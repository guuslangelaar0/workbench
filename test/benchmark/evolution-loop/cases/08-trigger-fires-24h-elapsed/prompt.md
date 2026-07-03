Treat the current time as the timestamp in
`.workbench/evolution/NOW-for-eval-fixture-only` (a fixture-only marker
file — read it first). Check whether an evolution-loop summit should run
right now. The admin track's unblocked backlog is fully stocked (well above
the "keep 2-3 queued" threshold) — but `.workbench/evolution/last-summit`
(the stamp of when the last summit ran) is timestamped more than 24 hours
before that current time. Decide whether the trigger condition fires, and
if it does, run the summit (this exercises the retrospective mandate so it
doesn't get starved during quiet periods); if it doesn't, say so and don't
run one.
