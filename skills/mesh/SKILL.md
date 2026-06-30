---
name: mesh
description: Use when coordinating Claude sessions, devices, leads, workers, rooms, chat, status requests, help requests, handoffs, availability, or the Workbench Mesh command center.
---

# Workbench Mesh

Use Workbench Mesh for cross-session, cross-device, and teamlead communication inside a workbench project. Users usually speak in outcomes, not protocol details; map those outcomes to `/workbench:mesh` operations.

## Routing

- Use `/workbench:mesh status` and `/workbench:mesh who` before guessing who is connected or what they are doing.
- Use `/workbench:mesh room <name>` for shared lead, task, incident, or project channels.
- Use `/workbench:mesh message <target> <text>` for direct chat or room updates.
- Use `/workbench:mesh ask <target> <question>` for status, blocker, help, or clarification requests.
- Use `/workbench:mesh handoff <task-id> <target>` only when the user wants work transferred or delegated.
- Use `/workbench:mesh availability <state>` and `/workbench:mesh doing <text>` to publish this session's current presence before coordinating.
- Use `/workbench:mesh invite --role <role>` only when another device or user needs to join over LAN.

Chat, status, and help are first-class mesh work. Do not reduce every cross-session interaction to a task handoff.

## Operating Rules

- Prefer structured mesh operations before prose summaries. Send the message, ask, room, handoff, or availability update first, then summarize the outcome.
- Same-user local authentication is automatic through local Workbench credentials.
- LAN joins require an invite token. Create short-lived, role-scoped invites for other devices or users.
- Public internet exposure is unavailable in this version. Never suggest tunneling or public exposure as a Workbench Mesh operation.
- Do not expose LAN unless the user clearly asked to connect another machine, another user, or multiple sessions over the network.
