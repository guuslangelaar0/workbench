# Workbench Codex Lane Observability Design

## Intent

Workbench already lets a lead dispatch a task to Codex through
`/workbench:codex-engineer`. The next gap is trust: a delegated Codex lane can
finish, vanish from the active Claude thread list, or leave partial artifacts
without a clear Workbench-facing status.

The user should be able to ask:

```text
What is Codex doing?
Did Codex finish that task?
Show me the jobs.
```

and get a concrete answer from Workbench state, not a guess based on whether a
callback arrived.

## Current State

The current Codex integration has the right foundation:

- `/workbench:codex-engineer <id>` dispatches to the OpenAI Codex plugin through
  `subagent_type: "codex:codex-rescue"`.
- The command starts a disk lane lease with `scripts/lane.sh`.
- The command tells the lead to use `--reconcile` when Codex finishes without a
  callback.
- Workbench Mesh already models jobs, actors, rooms, status, and a command
  center.
- `/workbench:mc` already shows task lifecycle, in-development work, decisions,
  suggestions, spend, and build state.

The missing piece is a unified observable job record. Today, the lease, task
notes, Codex active-thread state, git artifacts, mesh job events, and Mission
Control output are separate signals.

## Goals

1. Make each Codex dispatch create a durable Workbench job record.
2. Make `/workbench:codex-engineer <id> --reconcile` deterministic enough that
   a lead can trust it after dropped callbacks.
3. Surface Codex lane state in `/workbench:mc` and `/workbench:mesh jobs`.
4. Record enough output pointers and evidence paths that the user can inspect
   what Codex did without reading every task note manually.
5. Keep Workbench, not Codex, responsible for review and verification.
6. Keep the first implementation offline-testable; live Codex execution remains
   a gated follow-up.

## Non-Goals

- No direct shelling into another plugin's private Codex runtime.
- No requirement that Codex exposes live stdout streaming.
- No hosted dashboard or public-internet bridge.
- No mandatory mesh daemon for basic Codex observability.
- No automatic task verification just because Codex returned.

## Approaches Considered

### Recommended: Disk-First Job Ledger With Mesh Projection

Create a Workbench-owned job ledger under `.workbench/jobs/`. A Codex dispatch
creates a job record linked to the task id, owner, lane lease, command, runtime
mode, and expected reconcile command. Reconcile updates that record using disk
evidence: task notes, git status, recent commits, lane lease age, and
`claude agents` when available.

Mission Control reads the ledger directly. Mesh projects the same records as
job events when mesh is running, but mesh is not required for correctness.

This fits Workbench's existing durable-file model and avoids coupling to
undocumented Codex internals.

### Alternative: Mesh-Only Job Tracking

All Codex job state could live in the mesh event log and command center. That
would make the dashboard very clean, but basic delegation would become dependent
on a background service. It also weakens recovery when mesh was not started.

Reject this for the first implementation.

### Alternative: Poll Codex Runtime Directly

Workbench could try to watch Codex's own task/output files or runtime process.
That might expose richer live output, but it would depend on another plugin's
private layout and break when the Codex plugin changes.

Reject this. Use the public `Agent`/`claude agents` surfaces and disk artifacts
only.

## Product Behavior

### Dispatch

When `/workbench:codex-engineer <id>` launches a Codex lane, it should also
create a job record:

```text
.workbench/jobs/<job-id>.job
```

The job id should be stable enough to mention in output and short enough for
humans, for example `codex-0042-20260702T121500Z`.

The record should include:

- `job_id`
- `type=codex-engineer`
- `task_id`
- `task_file`
- `owner=codex`
- `status=running`
- `started_at`
- `updated_at`
- `branch`
- `runtime_mode` (`background`, `wait`, or `foreground`)
- `runtime_flags`
- `lane_file`
- `reconcile_command=/workbench:codex-engineer <id> --reconcile`
- `output_ref` when available
- `last_summary`
- `verification_hint`

The command output should tell the user:

```text
Codex job codex-0042-20260702T121500Z started.
Track it with:
  /workbench:codex-engineer 0042 --reconcile
  /workbench:mc
  /workbench:mesh jobs
```

### Reconcile

`/workbench:codex-engineer <id> --reconcile` should gather evidence in a fixed
order:

1. Latest Workbench job record for the task.
2. Lane lease state from `scripts/lane.sh status`.
3. Active Claude/Codex threads from `claude agents --json` when supported.
4. Task notes added after dispatch.
5. Git status and recent commits touching the task window.
6. Declared verification lines or command output noted by Codex.

It should classify the lane as one of:

| Status | Meaning | Next action |
|--------|---------|-------------|
| `running` | active thread or fresh lane heartbeat exists | wait or ask for status |
| `returned` | Codex returned in the current interaction | run `/workbench:verify <id>` |
| `needs-review` | no active thread, artifacts exist, verification is unclear | inspect diff then verify |
| `failed` | launch failed or Codex reported failure | re-dispatch or move task back |
| `dead` | no active thread and no useful artifacts | ask whether to re-dispatch |
| `verified` | Workbench verification completed | clear lane/job from active view |

The command must not claim completion merely because Codex is no longer active.
It should say what evidence it found and what Workbench should do next.

### Mission Control

`/workbench:mc` should gain a compact `Jobs` section when active job records
exist:

```text
Jobs
  codex-0042  running       task 0042  age 12m  last: editing checkout retry
  codex-0047  needs-review  task 0047  run /workbench:verify 0047
```

This should stay text-first and dense. It should not require mesh or a browser.

### Mesh Command Center

When mesh is running, `workbench-mesh jobs` and the browser command center should
show the same Workbench job records. The first implementation can project job
records into the existing mesh job state through the CLI wrapper rather than
inventing a new service dependency.

Browser detail can show:

- task id and title
- owner and runtime mode
- status
- age and last update
- reconcile command
- output/evidence reference
- action hints: verify, retry, stop/adopt when supported

### Output And Logs

Workbench cannot assume direct Codex stdout is available. Instead:

- `output_ref` points to the best inspectable source Workbench owns: task notes,
  a job snapshot file, or a captured Agent result when available.
- `last_summary` stores a short human-readable status from dispatch/reconcile.
- If future Codex plugin APIs expose a stable output stream, Workbench can add a
  richer `output_ref` without changing the job contract.

## Architecture

### Components

- `scripts/job.sh`: small helper for creating, updating, listing, and resolving
  Workbench job records.
- `commands/codex-engineer.md`: uses `job.sh` during dispatch and reconcile.
- `scripts/mc.sh`: reads active job records and renders the `Jobs` section.
- `scripts/mesh.sh`: exposes `jobs` from the same ledger and can emit mesh job
  events when the service is running.
- `skills/codex-bridge/SKILL.md`: teaches leads to trust the job ledger and
  reconcile command, not callback memory.
- `skills/orchestration/SKILL.md`: teaches the loop to inspect active jobs before
  dispatching more work.
- Tests: shell tests for job ledger behavior, Codex command contract, Mission
  Control rendering, and mesh job visibility.

### Job Record Format

Use the same simple key-value style as lane files:

```text
job_id=codex-0042-20260702T121500Z
type=codex-engineer
task_id=0042
owner=codex
status=running
started_at=2026-07-02T12:15:00Z
updated_at=2026-07-02T12:15:00Z
branch=feature/checkout
runtime_mode=background
runtime_flags=--model spark --effort high
lane_file=.workbench/lanes/0042.lane
reconcile_command=/workbench:codex-engineer 0042 --reconcile
output_ref=.workbench/jobs/codex-0042-20260702T121500Z.snapshot.md
last_summary=Codex dispatched; waiting for artifacts.
verification_hint=/workbench:verify 0042
```

Key-value keeps the helper portable and consistent with `lane.sh`. A later Rust
or JSON projection can read it without changing command behavior.

### Data Flow

Dispatch:

```text
lead -> /workbench:codex-engineer 0042 --background
     -> claim task
     -> move task to in-development
     -> lane.sh start 0042 --owner codex
     -> job.sh start codex-engineer 0042
     -> Agent codex:codex-rescue
     -> task note + job snapshot
```

Reconcile:

```text
lead -> /workbench:codex-engineer 0042 --reconcile
     -> job.sh latest 0042
     -> lane.sh status 0042
     -> claude agents --json best-effort
     -> git/task evidence scan
     -> job.sh update status/summary/output_ref
     -> user sees next action
```

Mission Control / Mesh:

```text
mc.sh / mesh.sh jobs
  -> job.sh list --active
  -> render compact terminal rows
  -> mesh command center projects rows into jobs view when daemon exists
```

## Error Handling

- If job creation fails before Codex launch, stop and do not launch Codex.
- If job creation succeeds but Agent launch fails, mark the job `failed`, append
  a task note, and leave the task in `in-development`.
- If `claude agents --json` is unavailable, reconcile still works from disk and
  records that live thread state was unavailable.
- If a job record is malformed, `job.sh list` should skip it with a warning
  rather than breaking Mission Control.
- If multiple Codex jobs exist for one task, reconcile chooses the newest
  non-terminal job and shows older attempts as history.
- If a lane goes stale repeatedly, the existing lane attempts count remains the
  source for restart intensity.

## Testing

Required offline tests:

1. `test/job.test.sh`
   - starts a Codex job record
   - updates status and summary
   - lists active jobs
   - resolves latest job for a task
   - skips malformed records safely
2. `test/codex.test.sh`
   - `/workbench:codex-engineer` mentions job start/update and reconcile
   - command still uses `codex:codex-rescue`, not private Codex scripts
   - command records callback-less completion guidance
3. `test/mc.test.sh` or existing Mission Control tests
   - renders a `Jobs` section for active Codex jobs
   - hides terminal `verified`/`cancelled` jobs from active view
4. `test/mesh-ops.test.sh` or mesh command tests
   - `/workbench:mesh jobs` reads Workbench job records
   - mesh jobs output includes Codex task id, status, and next action
5. `bash test/all.sh`
   - full offline suite remains green

Optional live tests:

- A gated Codex live e2e can dispatch a tiny fixture task and assert that a job
  record is created before the Agent call. It should not be required for normal
  CI until a stable Codex test fixture exists.

## Release Scope

This is a good `v0.8.0` feature because it changes the user-visible delegation
model. The release note should say:

- Workbench now tracks Codex engineer lanes as durable jobs.
- Mission Control and mesh jobs show Codex lane status and next actions.
- Reconcile no longer depends on a callback; it classifies jobs from disk,
  thread state, task notes, and git artifacts.

## Open Risks

- The Codex plugin may not expose stable live output. The design avoids relying
  on that but leaves room for future richer output refs.
- Too much job detail can clutter Mission Control. The terminal view should show
  only active jobs and one-line next actions.
- Reconcile heuristics can be overconfident. The wording must separate evidence
  from inference and keep Workbench verification mandatory.
- Mesh and disk job views can drift if they store separate truth. Disk remains
  canonical; mesh is a projection.

## Self-Review

- Placeholder scan: no unfinished markers remain.
- Scope check: focused on Codex/job observability, not default mesh startup,
  public bridges, or full worktree policy.
- Ambiguity check: disk job records are canonical; mesh and Mission Control read
  or project them.
- Consistency check: Codex implements, Workbench verifies; this is preserved
  across dispatch, reconcile, and UI surfaces.
