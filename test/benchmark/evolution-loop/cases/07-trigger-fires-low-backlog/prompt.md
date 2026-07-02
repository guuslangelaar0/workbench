Treat the current time as the timestamp in
`.claude/admin-evolution/NOW-for-eval-fixture-only` (a fixture-only marker
file — read it first). Check whether an evolution-loop summit should run
right now. The admin track's unblocked backlog currently has 2 tasks, and
the configured threshold (`.workbench/config.json`, evolution-loop
settings) is "keep at least 3 queued." The last summit ran recently (well
under 24h before that current time). Decide whether the trigger condition
fires, and if it does, run the summit; if it doesn't, say so and don't run
one.
