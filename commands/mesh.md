---
description: Coordinate Claude sessions/leads/workers over the local/LAN Workbench Mesh command center
allowed-tools: ["Bash", "Read"]
---

Use this when the user asks to connect another Claude session, bring in another device, open a channel between leads, ask another lead/worker for status/help, hand off work, show who is working, or open the command center.

Run `${CLAUDE_PLUGIN_ROOT}/scripts/mesh.sh $ARGUMENTS`.

Prefer natural outcome routing:
- "talk to my MacBook Claude" -> status, start if needed, invite/connect instructions.
- "open a channel for leads" -> room create + message.
- "ask worker status" -> ask/status request.
- "show me the team" -> who/status.

Never expose LAN unless the user clearly asked to connect another machine or multiple users. Never expose public internet in this version.
