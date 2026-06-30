---
description: Designate this session a topic lead — scope task-picking to one Track and announce ownership to other live sessions
allowed-tools: ["Bash", "Read"]
argument-hint: "<topic>"
---

Make THIS session the lead for one topic/track, so several teamleads can run in one project without colliding. Follow the `coordination` skill.

1. Parse the `<topic>` from `$ARGUMENTS` (e.g. `storage`, `mobile`, `web`). If none was given, ask which track this session should lead.
2. Announce ownership by setting your coord label, then look at who else is live:
   - `bash "${CLAUDE_PLUGIN_ROOT}/scripts/lead.sh" set --target "${CLAUDE_PROJECT_DIR}" --session-id "<session-id>" --mode track --track "<topic>" --purpose "lead <topic> track"`
   - `bash "${CLAUDE_PROJECT_DIR}/scripts/coord/wb-coord" ping "lead:<topic>"`
   - `bash "${CLAUDE_PROJECT_DIR}/scripts/coord/wb-coord" who`
   If another live session already leads this `<topic>`, stop and pick a different track (or coordinate) — never double-lead a track. (If `scripts/coord/wb-coord` doesn't exist, this project is minimal-profile and single-session; just proceed as the sole lead.)
3. For the rest of this session, **scope your orchestration loop to this track**: in the pick step, only take backlog tasks whose `**Track:** <topic>` matches — other tracks belong to other leads. Before claiming a task, verify it's free with `wb-coord claims task:<id>`. The in-review cap is **shared across all leads** — respect it globally, not per-track.
4. Dispatch and verify exactly as the `orchestration` skill describes. `/workbench:dispatch` claims the task (`wb-coord claim task:<id>`) and writes the owner line; other leads see your claim and the file leaving `backlog/`, and skip it.

Report: the track you now lead, any other live leads and their tracks, and how many backlog tasks carry `**Track:** <topic>`.
