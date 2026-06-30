# Lead Purpose Parking Design

## Intent

Workbench leads should behave like purposeful human leads: each active lead session has a clear current mission, and unrelated discoveries are parked into the backlog instead of being absorbed into the current feature. This keeps the current branch/task focused while preserving useful bugs, ideas, and follow-up work as real workbench tasks.

## Design

Add a durable lead-purpose record under `.workbench/leads/`, keyed by Claude session id. A record stores the lead's purpose, mode (`task`, `track`, `backlog-scout`, or `unassigned`), active task id, track, branch, status, timestamps, and the parking policy. `SessionStart` and `UserPromptSubmit` hooks surface that purpose back into the model context. If a new session has no purpose, workbench should point at the most recent open lead and suggest either continuing it or picking from backlog.

Parking is task-first. A tangent becomes a backlog task with origin metadata: origin session, origin task, origin purpose, origin branch, and type (`bug`, `feature`, or `follow-up`). If there is already code for the tangent, the lead captures the relevant diff in the parked task and only reverts changes after explicit confirmation.

## Surfaces

- `scripts/lead.sh`: manages lead-purpose files.
- `scripts/park.sh`: creates backlog tasks with parked-origin metadata.
- `/workbench:lead`: status, set, adopt, and clear purpose.
- `/workbench:park`: park an out-of-scope bug/feature/follow-up into backlog.
- `skills/lead-purpose`: lead behavior rules for purpose, backlog selection, and parking.
- `hooks/bin/lead-purpose-nudge.sh`: injects the current purpose into prompt turns and reminds the lead to park unrelated scope.
- `hooks/bin/ground-session.sh`: includes the current or latest open lead purpose in the boot brief.

## Release Note

This is feature work and should land under `[Unreleased]`. A later release should follow the existing pattern: a final `release: vX.Y.Z ...` commit that updates `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`, and `CHANGELOG.md`, then tags the same commit.
