---
description: Coordinate Claude sessions/leads/workers over the local/LAN Workbench Mesh command center
argument-hint: "[start|stop|status|who|jobs|open|invite|connect|devices|revoke-device|room|message|ask|handoff|availability|activity|doing|watch|tail|inbox|listen|listen-wait]"
allowed-tools: ["Bash", "Read", "AskUserQuestion"]
---

Use this when the user asks to connect another Claude session, bring in another device, open a channel between leads, ask another lead/worker for status/help, hand off work, show who is working, or open the command center.

Run `${CLAUDE_PLUGIN_ROOT}/scripts/mesh.sh $ARGUMENTS`.

Wizard on missing required values: bare `/workbench:mesh` routes naturally per the outcomes below, but an operation invoked with required pieces missing (`connect URL TOKEN`; `message`/`ask`/`handoff` targets; `revoke-device DEVICE`; `tail --as`; `room NAME`; `doing STATE`; `availability STATE`; `watch ACTOR`; `activity STATE`) must not fail or dump usage — use AskUserQuestion for exactly the missing values (for `connect`, offer to read a pending invite's connect lines when `.workbench/mesh/server.json` exists; for message/ask/handoff/revoke targets, offer live candidates from `who`/`devices`), confirm the assembled command, then run it. (`invite`'s `--role`/`--ttl-seconds` already have working defaults — worker role, 3600s TTL — so don't prompt for them unless the user wants to override.)

Prefer natural outcome routing:
- "talk to my MacBook Claude" -> status, start with `start --lan` if no LAN mesh is running, create `invite --role worker --ttl-seconds 900`, then show `/workbench:mesh connect URL TOKEN` using hostname/mDNS and raw IP forms (device defaults to hostname if omitted).
- "stop the mesh" / "shut down the command center" -> `stop`. It reads the pid file `start` wrote (defaults to `.workbench/mesh/server.pid` next to `server.json` unless `start` was given an explicit `--pid-file`) and sends the process a clean SIGTERM — never SIGKILL. Report whether it stopped, was already down, or is still running after 5s.
- "open a channel for leads" -> `room <name>` and then `message <name> <text>` when the request includes something to say.
- "ask this room what they are touching" -> `message <room> what are you touching?` because rooms use chat messages.
- "ask worker status" -> `ask <actor> <question>` because individual actors use status/help requests.
- Note: targeting a message at an actor name (rather than a room) routes it to a room named after that actor — this is a convenience for 1:1-style conversations, not a security boundary. Any session holding this project's mesh credential can read any room, including these. There is no per-room access control today.
- "stream this session's output to the mesh" / "show what this agent is doing live on the bench" -> pipe the session's stream-json through `tail --as <actor>`, e.g. `claude -p "fix the bug" --output-format stream-json --verbose | ${CLAUDE_PLUGIN_ROOT}/scripts/mesh.sh tail --as generator-1 --provider claude --model sonnet` (Codex: `codex exec --json ... | mesh.sh tail --as <actor> --provider codex --model <model>`). It tees stdin through unchanged, so it drops into an existing pipeline without swallowing output.
- "tag my presence with the model/provider I'm running" -> pass `--provider <claude|codex>` and `--model <name>` on `availability`/`doing` (or export `WORKBENCH_MESH_PROVIDER` / `WORKBENCH_MESH_MODEL`); they default to "unknown" and show up on the dashboard so a lead can route by engine.
- "show who is hosting the mesh" -> `start --as <actor>` stamps the host actor into the server metadata; that name surfaces on the command center's Host surface. `start --bind local|lan` is equivalent to `--local`/`--lan`, when the caller prefers spelling the mode as a flag value.
- "always respond when someone messages me on the mesh" -> arm `mesh.sh inbox --as <actor> --wait` as a background task; it exits when a message arrives (the harness re-invokes the session on completion — a push channel), reply, then re-arm. One-shot `inbox --as <actor>` drains unread messages.
- "start a connector so I get instant wake instead of polling" -> `listen --as <actor>` runs the `workbench-mesh listen` connector in the foreground (background it with `&`/nohup/tmux); once running, `listen-wait --as <actor>` and `inbox --as <actor> --wait` pick up its instant FIFO wake instead of polling.
- "show me the team" -> who/status.
- "show connected devices" -> `devices`.
- "revoke the MacBook device" -> `revoke-device macbook`.
- "create a checkout lead room named lead:checkout, ask it what are you touching, and show who is connected" -> run `room lead:checkout`, `message lead:checkout what are you touching?`, then `who`.

Never expose LAN unless the user clearly asked to connect another machine or multiple users. Never expose public internet in this version.
