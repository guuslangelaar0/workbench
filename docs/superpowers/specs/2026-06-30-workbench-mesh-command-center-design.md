# Workbench Mesh Command Center Design

## Intent

Workbench should let Claude sessions behave like a real distributed team. The user should not have to ask for infrastructure such as "start a bridge" or "open a WebSocket." They should ask for outcomes:

- "Can you talk to my other Claude session on my MacBook?"
- "Open a channel for the checkout and architecture leads."
- "Ask the test worker to verify this branch."
- "Invite Sam to help on this project for the afternoon."
- "Show me what all leads are doing."

Claude maps those requests to workbench mesh operations. The mesh is the authenticated local/LAN control plane for sessions, leads, subagents, workers, jobs, rooms, messages, invites, and the human command center.

## Product Shape

Workbench Mesh has three first-class surfaces:

1. Claude-native interaction. Users speak naturally. Claude uses hooks and commands to discover mesh state, route intent, create invites, send messages, hand off tasks, and supervise workers.
2. Realtime agent protocol. Connected sessions exchange versioned JSON events over WebSocket. The protocol is structured, fast, replayable, and readable.
3. Human command center. A browser UI on the mesh service port shows live leads, workers, rooms, jobs, tasks, decisions, invites, and audit. It also lets humans approve, revoke, reassign, message, retry, stop, invite, adopt, and close.

The command center is not a marketing dashboard. It is the operating surface for a live AI team.

## Architecture

The mesh service is a normal background process, not a Claude session:

```text
Claude session(s)
  hooks + /workbench:mesh CLI
        |
        | JSON over local HTTP/WebSocket
        v
Workbench Mesh Service
  API + WebSocket + command center UI
        |
        | durable writes
        v
.workbench/mesh/
  events.jsonl
  sessions/
  devices/
  invites/
  jobs/
  rooms/
  audit.jsonl

Repo truth remains:
.claude/tasks/
.workbench/leads/
.claude/SESSION_STATE.md
```

Claude can start the mesh service as a background process, but the service should keep running independently enough to preserve event history, track stale sessions, and allow reconnection. Background Claude agents are workers; the mesh service is the control plane.

Default bind modes:

```text
local:
  bind 127.0.0.1
  same OS user can join through an authenticated local credential

lan:
  bind 0.0.0.0 or a selected LAN interface
  auth required
  print hostname.local, LAN IP, and port

public:
  not part of the first implementation slice
  later requires explicit confirmation and stronger transport setup
```

LAN invite output should always include friendly and raw addresses:

```text
Workbench mesh is available on this machine:

Host:
  guus-macbook.local:47321

LAN IP:
  192.168.1.42:47321

Local:
  127.0.0.1:47321

Invite:
  token: wb_invite_...
  role: worker
  expires: 15 minutes
```

## Security Model

Auth is always required, including same-user localhost. Local convenience comes from an OS-protected shared credential, not from no-auth.

Secrets live outside git:

```text
~/.workbench/mesh/devices/<device-id>.key
~/.workbench/mesh/projects/<project-id>.cred
```

Same-user same-host bootstrap:

1. The first Claude session starts the mesh.
2. Workbench creates a device root key if missing.
3. The mesh mints a project credential for that OS user.
4. Other Claude sessions from the same user on the same host authenticate silently with the local credential.

Other users or machines must use scoped invite tokens. Invite tokens are short-lived, can be single-use or limited-use, and are exchanged for durable device/session credentials.

Roles:

```text
owner:
  everything, including invites, revocation, exposure mode, and destructive control actions

operator:
  reassign, approve, stop or retry jobs, create rooms, request help

worker:
  accept handoffs, report status, submit evidence, participate in rooms

observer:
  read-only dashboard and room messages
```

Audit is mandatory for sensitive actions:

- invite created, accepted, expired, revoked
- device connected, disconnected, revoked
- role changed
- task claimed, handed off, reassigned
- job queued, started, cancelled, retried, completed, failed
- decision approved or denied
- LAN/public exposure changed

LAN exposure can be automatic only when the user clearly asks to connect another machine or multiple users on the network. Public exposure is never automatic.

## Realtime Protocol

Use versioned JSON events over WebSocket for the first implementation. This keeps the protocol inspectable by Claude, testable by shell scripts, and easy for open-source contributors. gRPC/protobuf can be added later if stable SDK clients need binary contracts or generated types.

Event envelope:

```json
{
  "v": 1,
  "id": "evt_...",
  "seq": 128,
  "type": "task.handoff",
  "room": "task:0042",
  "from": "session:lead-checkout",
  "to": "worker:macbook",
  "ts": "2026-06-30T12:10:22Z",
  "payload": {}
}
```

Protocol rules:

- Server assigns monotonic `seq`.
- Clients ACK important control events.
- Clients reconnect with last seen `seq` and replay missed events.
- Event IDs support dedupe.
- Human-readable text is allowed, but important fields must be structured.
- `.workbench/mesh/events.jsonl` is append-only enough to recover recent state.

Core event families:

```text
presence.join
presence.heartbeat
presence.stale
device.capabilities

room.created
room.member_added
message.sent
message.delivered
message.read
message.reply
message.mention
message.request_status
message.status_response
message.help_request
message.help_offer
message.conflict_warning

lead.purpose_set
lead.closed
lead.adopted

actor.spawned
actor.heartbeat
actor.status
actor.output
actor.done
actor.failed
actor.stale
actor.cancelled

task.claim
task.handoff
task.handoff.accepted
task.status
task.reassigned

job.queued
job.started
job.output
job.done
job.failed
job.cancelled

decision.request
decision.answer

invite.created
invite.accepted
invite.revoked
```

## Collaboration Rooms And Messages

General team communication is first-class. Not every interaction is a task handoff. Leads and workers need to ask each other for status, blockers, file touch points, help, conflict avoidance, and review.

Room types:

```text
repo:<project>          general project room
lead:<track>            track or feature lead room
task:<id>               task room
dm:<actor-a>:<actor-b>  direct chat
incident:<id>           temporary debugging room
```

Status request example:

```json
{
  "type": "message.request_status",
  "room": "dm:lead-checkout:worker-macbook",
  "from": "lead:checkout",
  "to": "worker:macbook",
  "payload": {
    "question": "Where are you on checkout retry?",
    "needs": ["files_touched", "current_blocker", "eta", "handoff_risk"]
  }
}
```

Status response example:

```json
{
  "type": "message.status_response",
  "payload": {
    "summary": "Tests are passing locally, cleaning up retry edge case.",
    "files_touched": ["src/checkout/retry.ts", "test/retry.test.ts"],
    "blocker": null,
    "eta": "10m",
    "handoff_risk": "low"
  }
}
```

The command center should show room chat, direct messages, mentions, status requests, help requests, and conflict warnings. Claude should also be able to send and answer these messages through `/workbench:mesh`.

## Actor Hierarchy

A lead session can spawn subagents, background Claude jobs, engineers, verifiers, and external workers. The mesh must show this hierarchy so a lead does not look idle while its child actors are busy.

Model:

```text
Session
  a live Claude Code conversation, tab, or process

Actor
  anything doing work:
  - human-facing lead session
  - subagent
  - background worker
  - verifier
  - remote worker

Job
  a concrete execution attempt owned by an actor
```

Example tree:

```text
Checkout Lead                         active
  Engineer subagent 0042              running   touching retry.ts
  Verifier subagent 0042              queued
  Background test job                 running   npm test checkout
```

Actor record:

```json
{
  "actor_id": "actor_...",
  "kind": "lead|session|subagent|worker|verifier|job",
  "parent_id": "session_...",
  "root_session_id": "session_...",
  "purpose": "implement task 0042",
  "task_id": "0042",
  "status": "running",
  "capabilities": ["code-edit", "test-runner"],
  "started_at": "...",
  "last_seen_at": "...",
  "files_touched": [],
  "current_step": "running checkout retry tests"
}
```

Telemetry can be partial at first. Workbench should still register intent, freshness, and completion even when detailed live output is unavailable.

## Command Center

The command center is served by the same mesh service port as the API/WebSocket.

Views:

- Overview: active leads, workers, stale sessions, current jobs, conflicts, unread mentions.
- Leads: purpose, active task, branch, last seen, child actors, adopt, close, reassign.
- Workers: device, role, capabilities, current job, logs, stop, retry.
- Rooms: repo, lead, task, direct, and incident rooms.
- Jobs: queued, running, done, failed, output, evidence.
- Tasks: lifecycle board plus claims, handoffs, ownership, file touch points.
- Decisions: approval queue with accept, deny, comment.
- Invites: create, copy, revoke, expiry, role, scope.
- Audit: chronological security and control events.

Human browser actions should emit structured mesh events. If a user approves a decision or reassigns a task in the browser, connected Claude sessions learn it immediately through the same protocol.

## Terminal Statusline

Workbench should include an optional Claude Code `statusLine` script for mesh presence. It should show the local session purpose and a compact team pulse:

```text
workbench | checkout lead | busy: retry tests | team 3 active, 1 stale | macbook testing 0042
```

Statusline content:

- current session role and purpose
- availability: available, busy, blocked, reviewing, away
- current task/job
- connected leads and workers
- stale sessions
- conflict warnings
- unread mentions or help requests

The statusline command must not perform network calls on every render. The mesh service writes a cached snapshot such as:

```text
~/.workbench/mesh/statusline/<project-id>.json
```

Claude and the command center both update the same presence model. Changing availability in either place updates the other.

## Claude Intent Routing

Claude should never require users to know mesh internals. Example mapping:

User:

```text
Can you ask the MacBook session to test this?
```

Claude:

1. Reads mesh status from hook context or `/workbench:mesh status`.
2. Finds available devices and capabilities.
3. Creates or reuses `task:<id>` room.
4. Sends `task.handoff` or `message.help_request`.
5. Waits for `task.handoff.accepted` or a status response.
6. Tracks job/evidence in task metadata.

Common user intents:

- connect another Claude session
- connect another machine on LAN
- invite another user
- open a channel for leads
- ask another lead or worker for status
- ask for help
- warn about file conflicts
- hand off a task
- watch a worker in the statusline
- reassign stale work
- adopt or close a stale lead
- approve or deny a decision

Slash commands remain the API:

```text
/workbench:mesh status
/workbench:mesh start
/workbench:mesh start --lan
/workbench:mesh invite --role worker
/workbench:mesh connect <url> <token>
/workbench:mesh who
/workbench:mesh room <name>
/workbench:mesh message <target> <text>
/workbench:mesh ask <target> <question>
/workbench:mesh handoff <task-id> <target>
/workbench:mesh jobs
/workbench:mesh availability <state>
/workbench:mesh doing <text>
/workbench:mesh watch <actor>
```

## First Implementation Slice

The chosen product direction is the full collaborative command center. The first implementation should still ship as a coherent slice:

1. Mesh service starts locally or on LAN and prints host, IP, port, and invite details.
2. Auth works for same-user localhost through OS-protected local credentials.
3. Invite tokens work for LAN machines and other users.
4. WebSocket JSON protocol supports presence, rooms, messages, invites, actors, jobs, and basic task handoff events.
5. Hook context tells each Claude session whether mesh is running and who is connected.
6. `/workbench:mesh` exposes status, start, invite, connect, who, room, message, ask, handoff, availability, doing, and watch.
7. Command center shows live overview, leads, workers, rooms, jobs, tasks, decisions, invites, and audit.
8. Terminal statusline reads a cached mesh snapshot.
9. Event log and audit log survive service restart.

Public internet exposure, bridge federation, WebRTC DataChannels, MCP/Channel adapters, and gRPC/protobuf are deferred. They are not separate products or optional sidecars; they are later transport, tool, and deployment extensions of the same mesh control plane.

## Open Risks

- Browser command center scope can sprawl. The first version should favor dense operational views over polish.
- Claude background job behavior may vary by host version. The mesh should treat background jobs as workers but keep its own job records.
- Some subagent telemetry may not be available in realtime. The actor model must tolerate partial updates.
- LAN discovery through `.local` may fail on some networks. Always print raw IP and port as fallback.
- Auth and secret storage must be tested carefully across same-user, different-user, and LAN paths.
- Statusline must be fast and non-blocking, otherwise it will degrade the Claude terminal experience.
