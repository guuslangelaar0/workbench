---
description: Operate this project remotely over Telegram (status + decisions from your phone) — setup status, the run command, and the security model
allowed-tools: ["Bash", "Read"]
---

Set up / operate remote control for this project. **Invoke the `remote` skill and follow it.**

1. Read `way_of_working.remote` from `.workbench/config.json`.
   - If it's `off`, tell the user remote isn't enabled and point them at `/workbench:setup` (the `remote` axis) to turn on Telegram or native Remote Control — then stop.
   - If it's `telegram`/`both`/`native`, give the operating brief from the `remote` skill.
2. For Telegram: confirm the official plugin is installed and paired (install steps are in `/workbench:setup`), then show the run command — run the loop in a persistent terminal: `tmux new -s workbench` → `claude --channels plugin:telegram@claude-plugins-official` → `/workbench:loop`.
3. Restate the security model: bot token only in `~/.claude/channels/telegram/.env` (never git), `/telegram:access policy allowlist`, and the `PreToolUse` guard that blocks catastrophic commands. Confirm the outbound `Notification` hook is active (it pings you on permission/idle prompts when `remote != off`).
4. Remind: answer status from disk (tasks + `wb-coord who` + SESSION_STATE + estimates); route decisions to chat but never stall the loop — the `decisions/` file on disk is the durable fallback.
