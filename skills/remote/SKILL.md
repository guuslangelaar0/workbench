---
name: remote
description: Use when operating a workbench project remotely (remote != off) — running the loop over the official Telegram Channels plugin, answering status and decisions from your phone, the disk-based fallback when the session is down, and the security model (allowlist, secrets out of git, the PreToolUse guard). Setup/install lives in the setup wizard; this is how to run it.
---

# Remote operation (Telegram)

Workbench **composes** the official `telegram@claude-plugins-official` Channels plugin — it does not reinvent it. Installation/pairing is covered by `/workbench:setup` (the `remote` axis). This skill is how you **operate** once it's configured, plus the security model. Applies when `way_of_working.remote` is `telegram` or `both`.

## Running the loop over Telegram (Channels)
- Channels is a bidirectional Telegram↔session bridge (research preview, needs Bun) and **only works while the session is running**. Run the loop in a persistent terminal: `tmux new -s workbench` then `claude --channels plugin:telegram@claude-plugins-official`, and start `/workbench:loop`.
- **Status queries** ("who's working on what", "what's blocked", estimates): answer from **disk**, not memory — read `.claude/tasks/` counts, `scripts/coord/wb-coord who`, `.claude/SESSION_STATE.md`, and the tasks' `**Estimate:**` fields, then reply in chat.
- **Decisions**: when a honesty trigger fires, send the decision to the chat (the title, the options, your recommendation) and treat the reply as the answer — then continue the loop. Don't stall the loop waiting on chat.

## The fallback when the session is down (disk is the seam)
Channels only bridges a live session. If the session is down, a honesty trigger still writes a `.claude/tasks/decisions/` file on disk; the next `SessionStart` re-grounds and surfaces it (the `session-continuity` skill). So the durable record is always the `decisions/` file — Telegram is the fast path, disk is the reliable one.

## Outbound nudges (the Notification hook)
Workbench ships a `Notification` hook (`notify.sh`) that pings Telegram on `permission_prompt`/`idle_prompt`, so you're nudged even when you're not watching the chat. It reads the bot token + chat id from `~/.claude/channels/telegram/.env` and no-ops silently if `remote` is `off` or the credentials are absent.

## Security model (non-negotiable)
- **Secrets never in git.** The bot token lives only in `~/.claude/channels/telegram/.env`. Never commit it; never echo it. (A `check-secrets` pre-commit hook backs this up.)
- **Allowlist-only.** Pair the bot to your chat and set `/telegram:access policy allowlist` so only you can drive the session.
- **The hard guard.** Workbench ships a `PreToolUse` guard (`remote-guard.sh`) that hard-blocks (exit 2) a narrow set of catastrophic, irreversible commands — `rm -rf` of root/home, `git push --force` — even under bypass/auto-approve mode, so a misread remote message can't destroy the machine. It's a safety net, not a full sandbox: treat genuinely destructive or irreversible actions as local-only with explicit approval, regardless of channel.

## Native alternative
Remote Control (the Claude app / claude.ai/code, push to phone via `/config`) is the complementary `native` option and can run alongside Channels. It needs no bot token. Pick `telegram` for two-way chat control, `native` if you live in the Claude app, or `both`.
