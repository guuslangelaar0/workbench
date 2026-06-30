---
name: lead-purpose
description: Use when setting or resuming a lead session's purpose, running /workbench:lead, parking unrelated work with /workbench:park, or deciding whether a bug/feature/follow-up belongs to the current lead goal.
---

# Lead Purpose

A workbench lead is not an anonymous tab. It has a purpose: one feature/task, one track, or an explicit backlog-scouting pass. The purpose is durable state under `.workbench/leads/`, so a new session can resume it instead of relying on chat memory.

## Establish Purpose

At the start of lead work:

1. Read the current lead purpose with `scripts/lead.sh status --target "$CLAUDE_PROJECT_DIR" --session-id "<session-id>"`.
2. If none exists, read `scripts/lead.sh latest-open --target "$CLAUDE_PROJECT_DIR"`.
3. If a latest open purpose exists, offer to adopt it or pick from backlog.
4. If no purpose exists, choose a backlog task or intentionally enter `backlog-scout` mode before doing implementation work.

When `/workbench:dispatch <id>` starts a task, the session purpose becomes that task. When `/workbench:teamlead <track>` starts, the purpose becomes that track.

## Parking Rule

If a bug, feature idea, cleanup, or follow-up is not clearly part of the current purpose, park it. Do not widen the active task silently.

Parking means:

1. Create a real backlog task with `/workbench:park`.
2. Include origin metadata: current session, active task, purpose, branch, and any context or diff already gathered.
3. Keep the current purpose unchanged.
4. Do not implement the parked work until it is deliberately picked by the lead loop.

## Scope Expansion

Only expand the current purpose when the user explicitly chooses that. Record the expanded purpose with `scripts/lead.sh set` so future hook nudges stop treating it as unrelated.

## Completion

When the active purpose is verified/shipped or no longer owned by this session, close it with `/workbench:lead clear`. If work remains but the session is ending, leave it open so a future session can adopt it.
