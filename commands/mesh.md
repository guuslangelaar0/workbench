---
description: Coordinate Claude sessions/leads/workers over the local/LAN Workbench Mesh command center
allowed-tools: ["Bash", "Read"]
---

Use this when the user asks to connect another Claude session, bring in another device, open a channel between leads, ask another lead/worker for status/help, hand off work, show who is working, or open the command center.

Run `${CLAUDE_PLUGIN_ROOT}/scripts/mesh.sh $ARGUMENTS`.

Prefer natural outcome routing:
- "talk to my MacBook Claude" -> status, start with `start --lan` if no LAN mesh is running, create `invite --role worker --ttl-seconds 900`, then show `/workbench:mesh connect URL TOKEN <device>` using hostname/mDNS and raw IP forms.
- "open a channel for leads" -> `room <name>` and then `message <name> <text>` when the request includes something to say.
- "ask this room what they are touching" -> `message <room> what are you touching?` because rooms use chat messages.
- "ask worker status" -> `ask <actor> <question>` because individual actors use status/help requests.
- "show me the team" -> who/status.
- "show connected devices" -> `devices`.
- "revoke the MacBook device" -> `revoke-device macbook`.
- "create a checkout lead room named lead:checkout, ask it what are you touching, and show who is connected" -> run `room lead:checkout`, `message lead:checkout what are you touching?`, then `who`.

Never expose LAN unless the user clearly asked to connect another machine or multiple users. Never expose public internet in this version.
