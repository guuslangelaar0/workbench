#!/usr/bin/env bash
# correct behavior: a "backlog thin + summit overdue" observation should route to
# actually convening the panel (not just discussing it) — a new ledger entry AND a
# new backlog task file. Lightweight companion to the deep fixture cases in
# test/benchmark/evolution-loop/ — this one tests the natural-language TRIGGER phrase
# alone, without the plugin's own routing table (this case is intentionally `holdout`:
# evolution-loop isn't in the routing table yet, so it tests whether the summit
# command/skill's OWN description carries the intent, per the project's holdout
# convention in docs/design/2026-06-29-self-benchmarking-expectancy-design.md §6c).
set -uo pipefail
grep -qiE 'summit|evolution.?loop|ideas.?log' "$RUN_OUTPUT" 2>/dev/null || exit 1
grep -qE '^## Summit — [0-9]{4}-[0-9]{2}-[0-9]{2}' .workbench/evolution/ideas-log.md 2>/dev/null || exit 1
n="$(ls .claude/tasks/backlog/*.md 2>/dev/null | wc -l | tr -d ' ')"
[ "$n" -ge 1 ] || exit 1
exit 0
