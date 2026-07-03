---
name: mesh
description: Use when coordinating Claude sessions, devices, leads, workers, rooms, chat, status requests, help requests, handoffs, availability, or the Workbench Mesh command center.
---

# Workbench Mesh

Use Workbench Mesh for cross-session, cross-device, and teamlead communication inside a workbench project. Users usually speak in outcomes, not protocol details; map those outcomes to `/workbench:mesh` operations.

## Routing

- Use `/workbench:mesh status` and `/workbench:mesh who` before guessing who is connected or what they are doing.
- Use `/workbench:mesh stop` to cleanly shut down a mesh server started with `start` — it reads the same pid file `start` wrote (default `.workbench/mesh/server.pid`, or an explicit `--pid-file`) and sends SIGTERM, never SIGKILL.
- Use `/workbench:mesh room <name>` for shared lead, task, incident, or project channels.
- Use `/workbench:mesh message <target> <text>` for direct chat or room updates.
- Use `/workbench:mesh ask <target> <question>` for status, blocker, help, or clarification requests.
- Pass `--as <actor-name>` (or export `WORKBENCH_MESH_ACTOR`) on `message`/`ask`/`doing`/`availability`/`handoff`/`room create`/`watch` so this session posts under its own identity rather than the shared default `session:lead`. Always set this when more than one real session/process is expected to post into the same room — otherwise every sender looks identical in the room and dashboard.
- Use `/workbench:mesh handoff <task-id> <target>` only when the user wants work transferred or delegated.
- Use `/workbench:mesh availability <state>` and `/workbench:mesh doing <text>` to publish this session's current presence before coordinating. Add `--provider <claude|codex>` and `--model <name>` (or export `WORKBENCH_MESH_PROVIDER` / `WORKBENCH_MESH_MODEL`; both default to `unknown`) so presence is tagged with the engine and model, letting a lead route by provider.
- "stream this session's output to the mesh" -> pipe a live Claude/Codex session's stream-json through `mesh.sh tail --as <actor>`, e.g. `claude -p "fix the bug" --output-format stream-json --verbose | ${CLAUDE_PLUGIN_ROOT}/scripts/mesh.sh tail --as generator-1 --provider claude --model sonnet` (Codex: `codex exec --json`). It tees stdin through unchanged and appends `output.chunk` events into room `output:<actor>`, posting a presence heartbeat so the actor appears on the bench. `--as` (or `WORKBENCH_MESH_ACTOR`) is required.
- Pass `--as <actor>` to `/workbench:mesh start` to stamp the hosting actor into the server metadata; that name shows up on the command center's Host surface.
- Use `/workbench:mesh invite --role <role>` only when another device or user needs to join over LAN.
- Use `/workbench:mesh connect URL TOKEN [DEVICE]` when the user is on the joining machine and has an invite URL/token from another trusted LAN host.
- Use `/workbench:mesh devices` and `/workbench:mesh revoke-device <device>` to inspect and remove LAN device credentials.

Chat, status, and help are first-class mesh work. Do not reduce every cross-session interaction to a task handoff.

## Operating Rules

- Prefer structured mesh operations before prose summaries. Send the message, ask, room, handoff, or availability update first, then summarize the outcome.
- Same-user local authentication is automatic through local Workbench credentials.
- LAN joins require an invite token. Create short-lived, role-scoped invites for other devices or users.
- Public internet exposure is unavailable in this version. Never suggest tunneling or public exposure as a Workbench Mesh operation.
- Do not expose LAN unless the user clearly asked to connect another machine, another user, or multiple sessions over the network.
