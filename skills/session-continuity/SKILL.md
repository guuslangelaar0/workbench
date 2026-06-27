---
name: session-continuity
description: Use at session start/resume, before compaction concerns, and when checkpointing — the boot protocol, checkpoint discipline, and restart hygiene that keep the way of working alive across sessions.
---

# Session continuity

The way of working must survive compaction and new sessions. It is kept active by the workbench hooks (SessionStart re-grounds from disk; PreCompact records a marker) — but the durable, semantic state is YOUR responsibility to write.

## Boot (new or resumed session)
Run `/workbench:boot`: Phase 1 verify reality from disk (SESSION_STATE, tasks, git, build, prod), Phase 2 reconcile drift, Phase 3 brief in facts and wait for "go". Never trust chat memory over disk.

## Checkpoint discipline
Write `.claude/SESSION_STATE.md` on cadence (default every ~30 min of active work; sooner for risky work) and at any natural seam — `/workbench:checkpoint` does it. The test: could a brand-new session resume from SESSION_STATE alone? If not, it is not a real checkpoint. The SessionStart hook re-injects the "Now" snapshot, so keep that section current.

## Restart hygiene
A single session that runs too long drifts: in-memory state diverges from disk (phantom teammates, "I already did X" when X is not on disk, repeated stale-parameter tool failures). When you notice drift — or pass your wall-time budget — bank a full checkpoint to SESSION_STATE and start a fresh session that boots via `/workbench:boot`. Everything load-bearing is on disk and in git, so a restart is clean, not lossy.

## Honesty under continuity
Re-grounding shows you disk reality; trust it. Re-verify load-bearing claims (a SHA, a "verified", a prod state) against the actual source before acting on a remembered version of them.

## Surviving a hard crash — the external supervisor
Restart hygiene assumes *you* notice the drift and restart. But if the session dies outright — an API error, an Anthropic outage, the process killed — nothing in-agent runs to recover it (a stopped agent can't read "resume yourself"), and an in-session `ScheduleWakeup` cron dies *with* the session. So across-session continuity is owned by an **external supervisor**: `/workbench:supervise` → `scripts/watchdog.sh`, run by cron / `systemd --user` / tmux. It watches for a crash (a `StopFailure` recovery marker, written by `hooks/bin/stopfailure-recover.sh`) or a stall (`SESSION_STATE.md` gone stale), reaps phantom lanes (`lane.sh reap`), and relaunches a fresh `claude --resume` whose first act is `/workbench:boot`. The charter (`.workbench/loop-charter.md`) is the north star it re-grounds against. **Layer it, weakest→strongest:** in-session heartbeat (idle-but-alive) → `StopFailure` marker (records the death) → external supervisor (survives the death). The first two are within-a-tick; only the supervisor guarantees continuity across a session that has actually died.
