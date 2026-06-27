---
description: Set up the external supervisor that keeps the loop alive across crashes, stalls, and outages
allowed-tools: ["Bash", "Read"]
argument-hint: "[--session-id <id>] [install | status]"
---

You are the `/workbench:supervise` command. The supervisor is the **spine of loop durability** — and it lives *outside* the agent on purpose.

## Why an external supervisor

A directive in `CLAUDE.md`/`SOUL.md` ("never stop", "resume yourself") only runs while the agent is alive and reading it. The worst failures happen when it is **not**: the process died on an API error, the context compacted away the goal, or it wedged. **A thing cannot supervise itself.** So liveness is owned by a small, dumb, out-of-process loop that survives what the agent can't:

- **in-session heartbeat** (`ScheduleWakeup`) — handles idle-but-alive; dies with the session. *(weakest)*
- **`StopFailure` hook** (`hooks/bin/stopfailure-recover.sh`) — on an API-error turn-end, writes a recovery marker + optional alert. Can't resume.
- **external supervisor** (`scripts/watchdog.sh`, run by cron/systemd/tmux) — relaunches a fresh `claude --resume`, detects stalls, reconciles phantom lanes. **The spine.**

Each tick the supervisor reconciles disk state and, if the loop crashed (recovery marker) or stalled (`SESSION_STATE.md` older than `--max-idle`), it marks phantom lanes dead (`lane.sh reap`) and relaunches a fresh agent whose first act is `/workbench:boot` (re-ground from the charter + disk) then `/workbench:loop`. The git-tracked file tree *is* the durable workflow state; the agent is a replaceable per-tick worker driven against it.

## Read `$ARGUMENTS`

**`status` (default):** report whether a supervisor is configured and recent recovery activity:
```bash
ls -la "${CLAUDE_PROJECT_DIR}/.workbench/recovery/" 2>/dev/null || echo "no recovery dir yet (no failures recorded)"
crontab -l 2>/dev/null | grep -n watchdog.sh || systemctl --user list-timers 2>/dev/null | grep -i wb-watchdog || echo "no supervisor scheduled — run /workbench:supervise install"
```
Then show the dry-run decision the supervisor would make right now (needs the loop's session id — find it in your Claude Code session list):
```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/watchdog.sh" --session-id "<loop-session-id>" --project "${CLAUDE_PROJECT_DIR}"
```

**`install`:** help the human wire it for their runtime. The script self-documents a crontab line and a `systemd --user` unit/timer (`scripts/watchdog.sh --help`). Recommend **systemd-user** on Linux (survives terminal close, restarts on boot); a `*/5 * * * *` crontab as the portable fallback; or a foreground `tmux`/`nohup` loop for a dev box. The human supplies the loop's **session id** (so `--resume` targets the right conversation) and confirms `--exec`. Print the exact unit/cron with their paths filled in; do not enable it for them without confirmation — it launches `claude` unattended.

Keep it honest: the supervisor is the only layer that survives the session itself dying. Everything in-agent is within-a-tick behavior.
