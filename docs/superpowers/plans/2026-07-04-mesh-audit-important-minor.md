# Mesh Pre-Release Audit — Important + Minor Findings Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix all 27 Important and ~25 Minor findings from the 2026-07-04 mesh pre-release audit (`/tmp/claude-1000/-home-guus-code-workbench/db2a8692-420d-48e3-8d17-019b15fb99a0/scratchpad/audit-report.html`), not counting the 2 "ready to implement" feature designs (invite/connect UX redesign, LAN QR) which are new features with open questions for the user, not bugs, and are out of scope for this plan. The 7 Blockers were already fixed and merged to `main` in branch `fix/mesh-audit-blockers` (commits `eb4d4ca..cd0c178`, ledger at `.superpowers/sdd/progress.md`).

**Architecture:** Each task is an independent, self-contained fix scoped to a small file cluster (bash script, a handful of markdown docs, one Rust module, or one JS surface). Tasks are grouped by subsystem so a reviewer can hold the whole diff in mind. No task depends on another task's code changes (some touch the same file at disjoint line ranges — noted per task).

**Tech Stack:** Bash (`scripts/mesh.sh`, `scripts/*.sh`), Rust (`crates/workbench-mesh`, edition 2021, `anyhow`/`axum`/`serde_json`), vanilla JS (`crates/workbench-mesh/assets/command-center/*.js`, no build step, `el()` DOM helper in `ui.js`), Markdown command docs (`commands/*.md`, frontmatter + prose), `templates/schemas/*.json`.

## Global Constraints

- Branch: `fix/mesh-audit-important-minor`, based on `main` at `869525e`.
- Full test suite: `bash test/all.sh` (bash + JS harness tests) and `cargo test` (from `crates/workbench-mesh/`) must stay green after every task. Run the specific covering test file(s) named in each task at minimum; run the full suite before the final review.
- Do not touch the 2 "ready to implement" design sections (Invite/Connect UX redesign, LAN QR) — those are separate feature work pending user answers to open questions.
- Two findings needed a scoping call because the literal audit wording doesn't match a buildable fix at this scope — both are pinned below, do not re-litigate them per-task:
  - **"Direct" message privacy** (Protocol, Important): there is no membership/ACL system anywhere in workbench-mesh — any bearer-credentialed caller can already read any room. Building real per-room ACLs is a new subsystem, not a fix. Scope: make the docs honest (stop calling bare-actor-name sends "private"/"direct" without qualification; state plainly that any caller holding the project's bearer credential can read any room, including ones named after a person) — Task 11.
  - **"Send to nonexistent actor succeeds silently" + "watch has no existence check"** (Protocol + Mesh dashboard, Important): the server has no actor-registration step — `state_json`'s `actors` set (`server.rs:802-812`) is built by scanning event history for `from`/`to` fields, so a hard existence gate would reject the *first legitimate message to a brand-new actor* (chicken-and-egg: an actor only enters the set after someone messages them). Scope: emit a non-blocking stderr warning when `to` has no prior history in that set, instead of a hard reject — Task 9.
- Corrected finding: the audit's "`watch` renders as an opaque `?`" is factually a **blank/empty message bubble**, not a `?` character (verified: no `'?'` literal renders for this path anywhere in the JS). Fix the actual blank-bubble symptom, not a `?` glyph — Task 9.

---

### Task 1: Non-mesh command doc fixes

**Files:**
- Modify: `scripts/mc.sh:18-21`
- Modify: `commands/remote.md:12`
- Modify: `commands/verify.md:9`
- Modify: `commands/dispatch.md:4`
- Modify: `commands/claude-engineer.md:12-16`
- Modify: `commands/evolve.md:3`
- Test: `test/all.sh` (run the full suite; no new test files needed for these — they're prose/shell-guard fixes covered by existing script tests where they exist)

**Context:** Six independent, unrelated doc/script issues outside the mesh subsystem. Each is a small, surgical fix.

- [ ] **1. `scripts/mc.sh` walks into `~/.claude/tasks/`**

Current code (`scripts/mc.sh:18-21`):
```bash
# locate project root: walk up to a dir containing .claude/tasks
ROOT="$PWD"
while [[ "$ROOT" != "/" ]] && [[ ! -d "$ROOT/.claude/tasks" ]]; do ROOT="$(dirname "$ROOT")"; done
[[ -d "$ROOT/.claude/tasks" ]] || { echo "mc: no .claude/tasks/ found from $PWD upwards" >&2; exit 1; }
```
Problem: this only checks for `.claude/tasks` existing, with no check that `$ROOT` is a real workbench project (has `.workbench/config.json`) and no stop before `$HOME`, so from a subdirectory of `$HOME` with no local project it silently lands on `~/.claude/tasks/` (Claude Code's own internal storage) and renders a dashboard against it.

Fix: require `.workbench/config.json` alongside `.claude/tasks` as the real root marker, and stop the walk at `$HOME` (never walk above it):
```bash
# locate project root: walk up to a dir containing .claude/tasks AND
# .workbench/config.json (a real workbench project, not just any dir with
# a .claude/tasks/ subfolder — e.g. Claude Code's own ~/.claude/tasks/).
ROOT="$PWD"
while [[ "$ROOT" != "/" ]] && [[ "$ROOT" != "$HOME" ]] && { [[ ! -d "$ROOT/.claude/tasks" ]] || [[ ! -f "$ROOT/.workbench/config.json" ]]; }; do ROOT="$(dirname "$ROOT")"; done
[[ -d "$ROOT/.claude/tasks" ]] && [[ -f "$ROOT/.workbench/config.json" ]] || { echo "mc: no workbench project (.claude/tasks/ + .workbench/config.json) found from $PWD upwards" >&2; exit 1; }
```
Note: the loop condition stops walking once `$ROOT == $HOME` even if `$HOME` itself happens to contain both markers (unlikely, but the guard should still apply symmetrically) — the check after the loop still validates whatever `$ROOT` the loop landed on, so `$HOME` is correctly rejected if it doesn't have `.workbench/config.json` (it won't, in the reported scenario).

Verify by hand: `cd ~ && bash <path-to-repo>/scripts/mc.sh` (or the project's actual mc.sh path) should now print the "no workbench project found" error instead of rendering a dashboard. Also verify `cd` into this actual repo still works (`.workbench/config.json` must exist here — check with `ls .workbench/config.json`; if this repo has no such file, use whatever real marker file `scripts/setup.sh`/`init.sh` writes on project init — grep `scripts/init.sh` for the file it creates and use that exact path instead of assuming `.workbench/config.json`).

- [ ] **2. `commands/remote.md` overclaims Notification hook firing for native mode**

Current (`commands/remote.md:12`):
```
3. Restate the security model: bot token only in `~/.claude/channels/telegram/.env` (never git), `/telegram:access policy allowlist`, and the `PreToolUse` guard that blocks catastrophic commands. Confirm the outbound `Notification` hook is active (it pings you on permission/idle prompts when `remote != off`).
```
The hook's actual gate (`hooks/bin/notify.sh:14-23`) requires `remote != off` **and** `~/.claude/channels/telegram/.env` with `TELEGRAM_BOT_TOKEN`/`TELEGRAM_CHAT_ID` present — it no-ops silently for `remote: native` with no Telegram env file.

Fix line 12 to state the real condition:
```
3. Restate the security model: bot token only in `~/.claude/channels/telegram/.env` (never git), `/telegram:access policy allowlist`, and the `PreToolUse` guard that blocks catastrophic commands. Confirm the outbound `Notification` hook is active — it pings you on permission/idle prompts only when Telegram credentials (`TELEGRAM_BOT_TOKEN`/`TELEGRAM_CHAT_ID`) are configured in `~/.claude/channels/telegram/.env`, regardless of the `remote` setting; a `native`-only project with no Telegram env file will not get these pings.
```

- [ ] **3. `commands/verify.md` hardcodes `in-review/` which doesn't exist at `solo` level**

Current (`commands/verify.md:9`):
```
1. Parse the task `<id>` from `$ARGUMENTS`. If invoked without an `<id>` (or ambiguous), don't fail or dump usage — run a short wizard: use AskUserQuestion offering the tasks currently in `.claude/tasks/in-review/` (oldest first) as options, confirm the pick, then run the gate on it. Read its **verification contract** — the `**Verification:**` field, the `## Acceptance criteria`, the `## Scenarios`, and the `## Verification ladder`. These define "done"; they should have been written before dispatch.
```
`scripts/levels.sh:14-19`'s `wb_level_lifecycle` shows `solo` has stages `backlog in-development verified decisions` — no `in-review` stage at all. Fix the wizard to resolve the actual pre-verification stage from the configured level instead of hardcoding `in-review/`:
```
1. Parse the task `<id>` from `$ARGUMENTS`. If invoked without an `<id>` (or ambiguous), don't fail or dump usage — run a short wizard: resolve this project's actual pre-verification stage via `bash "${CLAUDE_PLUGIN_ROOT}/scripts/levels.sh" lifecycle --target "${CLAUDE_PROJECT_DIR}"` (the stage immediately before `verified` in the returned list — for `solo` that's `in-development`, for `pair`/`crew`/`fleet` it's `in-review`), then use AskUserQuestion offering the tasks currently in that stage's directory (oldest first) as options, confirm the pick, then run the gate on it. Read its **verification contract** — the `**Verification:**` field, the `## Acceptance criteria`, the `## Scenarios`, and the `## Verification ladder`. These define "done"; they should have been written before dispatch.
```
Before finalizing this wording, check `scripts/levels.sh` for the actual CLI invocation shape of `wb_level_lifecycle` (it may be a shell function only, not a subcommand with a `lifecycle` verb) — if there's no existing CLI entry point that prints the lifecycle list for a given project's level, add a minimal one (e.g. `scripts/levels.sh lifecycle --target <dir>` that sources the level config and calls `wb_level_lifecycle "$level"`, printing space-separated stage names) rather than duplicating the stage-list logic inline in the markdown doc.

- [ ] **4. `commands/dispatch.md` argument-hint lists Codex-only flags unconditionally**

Current (`commands/dispatch.md:4`):
```
argument-hint: "<id> [--engine claude|codex] [--worktree [name]|--shared] [--background|--wait|--reconcile] [--fresh|--resume] [--model <model|spark>] [--effort <level>] [lane/repo]"
```
`--reconcile`, `--fresh`/`--resume`, `--model`, `--effort` are Codex-only (per the command's own body, line 15: "This also covers `--reconcile`, `--fresh`/`--resume`, `--model`, and `--effort`" under the Codex branch only). Fix the hint to scope them to `--engine codex`:
```
argument-hint: "<id> [--engine claude|codex] [--worktree [name]|--shared] [--background|--wait] [--reconcile --fresh|--resume --model <model|spark> --effort <level> (codex only)] [lane/repo]"
```

- [ ] **5. `commands/claude-engineer.md` — `--worktree` + `--wait` contradiction**

Current (`commands/claude-engineer.md:12-16`):
```
1. Parse `$ARGUMENTS`: the task `<id>` (4-digit) and an optional lane/repo hint. If no explicit ID was supplied, do not guess and do not spawn a lane yet — run a short wizard instead: get candidates from `deps.sh ready`, use AskUserQuestion to pick the task, confirm the assembled dispatch, then continue with that ID.
   - `--worktree [name]`: prefer a native Claude Code worktree lane. Use the given name or `wb-<id>-<slug>`.
   - `--shared`: avoid a persistent/background worktree and use the normal foreground Task-tool path. The engineer agent can still run in Claude's temporary `isolation: worktree` sandbox.
   - `--background`: for a native CLI lane, launch it with `claude --worktree <name> --bg --agent engineer "<prompt>"`.
   - `--wait`: keep the engineer in the current session foreground path.
   - if `--background` and `--wait` are both present, stop and ask the user to choose one.
```
`--worktree --wait` together is undefined: does it mean a native worktree launched synchronously (blocking the session until it finishes), or does `--wait` silently downgrade to the foreground Task-tool path (making `--worktree` a no-op)? Fix by adding an explicit rule right after the `--wait` line:
```
   - `--wait`: keep the engineer in the current session foreground path.
   - `--worktree` with `--wait` (no `--background`): create the native worktree (per `--worktree` above) but run the engineer synchronously in the foreground Task-tool path against it, blocking until it completes — do not use `claude --bg`. `--worktree` alone (no `--background`/`--wait`) defaults to this same foreground-with-worktree behavior.
   - if `--background` and `--wait` are both present, stop and ask the user to choose one.
```

- [ ] **6. `commands/evolve.md` allowed-tools omits Write/Edit**

Current (`commands/evolve.md:3`):
```
allowed-tools: ["Bash", "Read", "Glob", "Grep", "Task", "TodoWrite"]
```
Line 21's `init` flow instructs rewriting `.workbench/evolution/personas.json` directly — no `Write`/`Edit` available. Fix:
```
allowed-tools: ["Bash", "Read", "Write", "Edit", "Glob", "Grep", "Task", "TodoWrite"]
```

- [ ] **7. Run the full suite and commit**

```bash
bash test/all.sh
git add scripts/mc.sh commands/remote.md commands/verify.md commands/dispatch.md commands/claude-engineer.md commands/evolve.md scripts/levels.sh
git commit -m "fix: mc.sh project-root guard, and 5 command-doc accuracy fixes"
```

---

### Task 2: Mesh docs discoverability (commands/mesh.md, skills/mesh/SKILL.md, CHANGELOG.md, spec doc)

**Files:**
- Modify: `commands/mesh.md:3` (argument-hint), `commands/mesh.md:11` (wizard clause)
- Modify: `skills/mesh/SKILL.md` (add `watch`/`activity` routing bullets)
- Modify: `CHANGELOG.md:9,16` (FIFO description)
- Modify: `docs/superpowers/specs/2026-07-03-mesh-command-center-redesign-design.md` (tab-count note)
- Test: `test/mesh-command-center.test.sh` (run existing suite; this task is docs-only, no new assertions needed)

**Context:** `jobs`, `activity`, `listen-wait` are real, working `mesh.sh` ops invisible from the docs; the wizard clause is missing 5 ops and treats `invite` role/ttl as required when defaults already exist; `watch`/`activity` have zero routing guidance in the skill doc; the CHANGELOG misdescribes the FIFO as server-written when it's client-side; the command-center redesign spec describes a 2-tab layout the shipped product doesn't have.

- [ ] **1. `commands/mesh.md:3` argument-hint — add `jobs`, `activity`, `listen-wait`**

Current:
```
argument-hint: "[start|stop|status|who|open|invite|connect|devices|revoke-device|room|message|ask|handoff|availability|doing|watch|tail|inbox]"
```
New (insert in the same op-family order `scripts/mesh.sh` defines them — `jobs` near `status`/`who`, `activity` near `availability`/`doing`, `listen-wait` near `inbox`):
```
argument-hint: "[start|stop|status|who|jobs|open|invite|connect|devices|revoke-device|room|message|ask|handoff|availability|activity|doing|watch|tail|inbox|listen-wait]"
```

- [ ] **2. `commands/mesh.md:11` wizard clause — add 5 missing ops, drop invite from "required"**

Current:
```
Wizard on missing required values: bare `/workbench:mesh` routes naturally per the outcomes below, but an operation invoked with required pieces missing (`connect URL TOKEN`; `invite` role/ttl; `message`/`ask`/`handoff` targets; `revoke-device DEVICE`; `tail --as`) must not fail or dump usage — use AskUserQuestion for exactly the missing values (...), confirm the assembled command, then run it.
```
`invite`'s role/ttl already default to `worker`/`3600s` in `scripts/mesh.sh:387-396` and `crates/workbench-mesh/src/server.rs:467` — it's never actually "missing," so drop it from the required-values list. Add `room NAME`, `doing STATE`, `availability STATE`, `watch ACTOR`, `activity STATE` (all of which hard-fail with a raw usage dump today when invoked bare — confirm each still requires a real positional arg by checking `scripts/mesh.sh`'s corresponding case block before finalizing wording). New text:
```
Wizard on missing required values: bare `/workbench:mesh` routes naturally per the outcomes below, but an operation invoked with required pieces missing (`connect URL TOKEN`; `message`/`ask`/`handoff` targets; `revoke-device DEVICE`; `tail --as`; `room NAME`; `doing STATE`; `availability STATE`; `watch ACTOR`; `activity STATE`) must not fail or dump usage — use AskUserQuestion for exactly the missing values (...), confirm the assembled command, then run it. (`invite`'s `--role`/`--ttl-seconds` already have working defaults — worker role, 3600s TTL — so don't prompt for them unless the user wants to override.)
```

- [ ] **3. `skills/mesh/SKILL.md` — add routing guidance for `watch` and `activity`**

Every other op (`room`, `message`, `ask`, `handoff`, `availability`, `doing`, `invite`, `connect`, `devices`/`revoke-device`, `tail`, `inbox`, `listen-wait`, `start`, `stop`) has its own bullet with routing guidance (lines 12-26); `watch` only appears once, folded into the `--as` flag-usage list (line 17), and `activity` doesn't appear at all. Read the file to find the exact bullet-list format used for siblings (e.g. how the `doing`/`availability` bullets are worded) and add two new bullets in the same style and position (alongside `doing`/`availability`, since `watch`/`activity` are semantically adjacent):
- `watch <actor>`: use when asked to "keep an eye on" / "check in on" another actor's work — posts a lightweight ping into their room, distinct from `message` (no content) or `ask` (expects a response).
- `activity <state>`: use to report this session's own live activity (`typing`/`reading`/`idle`) for presence display — distinct from `availability` (coarser online/away/busy state) and `doing` (a free-text one-line status).

- [ ] **4. `CHANGELOG.md:9,16` — fix FIFO ownership description**

Current (line 9, excerpt): `"the workbench-mesh listen command replaces the polling loop with an event-driven connector that wakes instantly via a FIFO push"` — this part is fine (doesn't claim server-side). Current (line 16):
```
- **`workbench-mesh listen` connector** — replaces polling with a push-driven model: the server writes a wake byte into a named FIFO (`<store>/listeners/<token>.fifo`) on every matching append, waking the listener with zero poll delay; where FIFOs are unavailable the connector falls back to lightweight short-poll. Reconnection uses exponential backoff capped at 5 s. The connector also measures and reports WebSocket app-level ping/pong round-trip time for diagnosing latency.
```
`crates/workbench-mesh/src/listen.rs:126-233` shows the **connector itself** creates (`mkfifo`) and writes the FIFO at `<project_root>/.workbench/mesh/inbox-<safe_actor>.fifo` (actor-keyed, not token-keyed, and not under a `listeners/` subdir) — `server.rs` has zero FIFO-related code. Fix line 16:
```
- **`workbench-mesh listen` connector** — replaces polling with a push-driven model: the connector process itself creates and holds open a named FIFO per actor (`<project_root>/.workbench/mesh/inbox-<actor>.fifo`), and writes a line into it the instant a matching event arrives over its WebSocket subscription — `listen-wait` blocks on this FIFO with zero poll delay while a connector is running, falling back to lightweight short-poll (`inbox --wait`) otherwise. Reconnection uses exponential backoff capped at 5 s. The connector also measures and reports WebSocket app-level ping/pong round-trip time for diagnosing latency.
```

- [ ] **5. Spec doc — annotate the 2-tab vs 5-tab mismatch**

`docs/superpowers/specs/2026-07-03-mesh-command-center-redesign-design.md:14-15,60` describes a 2-top-level-tab design ("Overview"/"Admin"); the shipped product (`crates/workbench-mesh/assets/command-center/app.js:72-76`) has 5 tabs (Bench/Board/Host/Ops/Docs) from a later, separate handoff. Don't rewrite the historical spec — add a short superseded-note at the very top of the file (after the title, before the first section) so future readers aren't misled:
```
> **Note (2026-07-04):** this spec's 2-tab design ("Overview"/"Admin") was superseded before ship by a later, uncommitted handoff that shipped the current 5-tab layout (Bench/Board/Host/Ops/Docs — see `crates/workbench-mesh/assets/command-center/app.js`). This document is kept for history; it does not describe the shipped product.
```

- [ ] **6. Run the full suite and commit**

```bash
bash test/all.sh
git add commands/mesh.md skills/mesh/SKILL.md CHANGELOG.md "docs/superpowers/specs/2026-07-03-mesh-command-center-redesign-design.md"
git commit -m "docs(mesh): surface jobs/activity/listen-wait, fix wizard clause + FIFO ownership + stale spec note"
```

---

### Task 3: mesh.sh error-message honesty (open, inbox, status/who/jobs)

**Files:**
- Modify: `scripts/mesh.sh:571-580` (`open)`), `scripts/mesh.sh:492-547` (`inbox)`), `scripts/mesh.sh:381-386` (`status)`/`who)`), `scripts/mesh.sh:451-464` (`jobs)`)
- Test: `test/mesh-acceptance*.sh` or wherever mesh.sh CLI behavior is asserted — run `bash test/all.sh`; add one new assertion (see step 4) confirming a friendly no-server message.

**Context:** `open` prints a vague "use a local project credential token when prompted" with no real token surfaced and no browser prompt exists; `inbox` swallows all diagnostic information behind `2>/dev/null` so real backend failures look identical to "empty inbox"; `status`/`who`/`jobs` let a raw Rust `anyhow` error string reach the user when no server has ever been started, while `open` already handles that same scenario cleanly. Note: this task and Task 4 both touch `scripts/mesh.sh` but at disjoint line ranges (this task: 283-332 excluded, 381-386, 451-464, 492-547, 571-580; Task 4: 283-332, 548-569) — do them sequentially, not in parallel, to avoid merge friction on the shared file.

- [ ] **1. `open)` — print the real token instead of a vague prompt claim**

Current (`scripts/mesh.sh:571-580`):
```bash
  open)
    if url="$(metadata_url)"; then
      printf 'Command center: %s\n' "$url"
      echo "Open the command center in a browser and use a local project credential token when prompted."
    else
      echo "mesh: no running mesh metadata found at $TARGET/.workbench/mesh/server.json" >&2
      echo "mesh: run /workbench:mesh start first" >&2
      exit 1
    fi
    ;;
```
There's already a `metadata_field` helper (`scripts/mesh.sh:106-110`) used elsewhere for reading named fields out of `server.json`. Use it to read and print `local_token` directly — no browser "prompt" exists, so stop implying one:
```bash
  open)
    if url="$(metadata_url)"; then
      token="$(metadata_field local_token)"
      printf 'Command center: %s\n' "$url"
      if [ -n "$token" ]; then
        printf 'Open that URL in a browser — it will use this project'"'"'s local token automatically via the ?token= link above.\n'
        printf 'If it asks again, paste this token: %s\n' "$token"
      else
        echo "mesh: no local_token found in $TARGET/.workbench/mesh/server.json — the server may need a restart"
      fi
    else
      echo "mesh: no running mesh metadata found at $TARGET/.workbench/mesh/server.json" >&2
      echo "mesh: run /workbench:mesh start first" >&2
      exit 1
    fi
    ;;
```
Before finalizing, check `metadata_url()` (`scripts/mesh.sh:96-104`) — confirm whether it already appends `?token=` to the URL it builds (the research notes `data.js:192` says "start prints a one-time local_token" and other code tokenizes asset URLs — grep `server.rs` static-asset serving for `?token=` handling, referenced at `server.rs` `static_headers`/tokenized html). If `metadata_url()` already returns a `?token=`-suffixed URL, simplify the message to just confirm that, rather than telling the user to separately "paste" a token that's already embedded in the printed link.

- [ ] **2. `inbox)` — stop swallowing real failures behind `2>/dev/null`**

Current relevant line (`scripts/mesh.sh:514`):
```bash
      out="$("$BIN" event list "${PROJECT_ARGS[@]}" --since "$since" 2>/dev/null | ACTOR="$actor" python3 -c '
```
Capture the binary's own exit status and stderr separately from the python post-processing, so a real failure (auth not bootstrapped, server down) is reported distinctly from "genuinely empty":
```bash
      if ! bin_out="$("$BIN" event list "${PROJECT_ARGS[@]}" --since "$since" 2>&1)"; then
        echo "mesh: inbox failed for $actor: $bin_out" >&2
        exit 1
      fi
      out="$(printf '%s' "$bin_out" | ACTOR="$actor" python3 -c '
```
Keep the rest of the loop body (the python post-processing, `top`/`body` parsing, `--wait` sleep loop) unchanged — only replace how `out` is produced, and only for the first attempt in the loop (if `--wait` is set and the call fails mid-poll, keep failing loudly rather than silently retrying forever — apply the same `if ! bin_out=...; then echo ... >&2; exit 1; fi` guard inside the `while true; do` loop too, not just once before it).

- [ ] **3. `status)`/`who)`/`jobs)` — friendly message when no server has ever started**

Current (`scripts/mesh.sh:381-386`):
```bash
  status)
    exec "$BIN" status "${PROJECT_ARGS[@]}" "$@"
    ;;
  who)
    exec "$BIN" who "${PROJECT_ARGS[@]}" "$@"
    ;;
```
Add the same guard `open)` already uses (check `server.json` exists before delegating), reusing `metadata_url()`'s existing pattern (it already returns non-zero when `server.json` is missing/unreadable — confirm this by reading its body at `scripts/mesh.sh:96-104` before writing the guard):
```bash
  status)
    if ! metadata_url >/dev/null 2>&1; then
      echo "mesh: no running mesh metadata found at $TARGET/.workbench/mesh/server.json" >&2
      echo "mesh: run /workbench:mesh start first" >&2
      exit 1
    fi
    exec "$BIN" status "${PROJECT_ARGS[@]}" "$@"
    ;;
  who)
    if ! metadata_url >/dev/null 2>&1; then
      echo "mesh: no running mesh metadata found at $TARGET/.workbench/mesh/server.json" >&2
      echo "mesh: run /workbench:mesh start first" >&2
      exit 1
    fi
    exec "$BIN" who "${PROJECT_ARGS[@]}" "$@"
    ;;
```
For `jobs)` (`scripts/mesh.sh:451-464`), add the same guard only around the final `exec "$BIN" jobs ...` fallback path (the `job.sh`-backed branch above it doesn't need mesh server metadata at all, so don't gate that branch):
```bash
  jobs)
    if [ -x "$PLUGIN_ROOT/scripts/job.sh" ]; then
      job_out="$(bash "$PLUGIN_ROOT/scripts/job.sh" list --active --target "$TARGET" 2>/dev/null || true)"
      if [ -n "$job_out" ]; then
        printf 'Workbench jobs:\n'
        printf '%s\n' "$job_out" | while IFS=$'\t' read -r job_id job_type task_id job_status job_summary; do
          [ -n "$job_id" ] || continue
          printf '  %s  %s  task:%s  %s\n' "$job_id" "$job_status" "$task_id" "$job_summary"
        done
        exit 0
      fi
    fi
    if ! metadata_url >/dev/null 2>&1; then
      echo "mesh: no running mesh metadata found at $TARGET/.workbench/mesh/server.json" >&2
      echo "mesh: run /workbench:mesh start first" >&2
      exit 1
    fi
    exec "$BIN" jobs "${PROJECT_ARGS[@]}" "$@"
    ;;
```

- [ ] **4. Add a regression test and run the suite**

Find the existing mesh CLI test harness (`test/mesh-command-center.test.sh` or a sibling `test/mesh-*.test.sh` that spins up a temp project and calls `scripts/mesh.sh` subcommands without starting a server first). Add one case: run `scripts/mesh.sh status --target <fresh-tmp-dir-with-no-server>` and assert the output contains `"run /workbench:mesh start first"` (the friendly message) rather than a raw Rust panic/error string. Then:
```bash
bash test/all.sh
```

- [ ] **5. Commit**

```bash
git add scripts/mesh.sh test/<the-test-file-you-edited>
git commit -m "fix(mesh): honest error messages for open/inbox/status/who/jobs"
```

---

### Task 4: mesh.sh listen wrapper + start --bind validation

**Files:**
- Modify: `scripts/mesh.sh` (add `listen)` case near `listen-wait)` at line 548; modify `start)` at lines 283-332)
- Modify: `commands/mesh.md` (document `--bind`; note: this touches the same file as Task 2, but Task 2 runs first and this is a small disjoint addition to the `argument-hint`/body — check Task 2's final state before editing to avoid reverting it)
- Test: `test/mesh-command-center.test.sh` or sibling — add coverage for the new `listen)` case and for `--bind` rejecting an invalid mode.

**Context:** `workbench-mesh listen` (the connector `listen-wait`'s fast path depends on) has no `mesh.sh` wrapper at all — a user has no documented way to actually start one. Separately, `start` accepts an undocumented `--bind MODE` flag with no validation, and prints its "success" banner (`print_start_info`) before the Rust binary would ever reject a bad mode.

- [ ] **1. Check the Rust `listen` subcommand's actual CLI signature**

Before writing the wrapper, read `crates/workbench-mesh/src/main.rs` for the `listen` subcommand's `clap` `Args` struct (search for `ListenArgs` or similar, alongside `ActivityArgs`/`InboxArgs` patterns already found). Confirm its exact flags (almost certainly `--target`/`--home`/`--as ACTOR`, matching `listen-wait`'s `--as` requirement) before writing the wrapper below — adjust flag names if they differ from this assumption.

- [ ] **2. Add a `listen)` case to `scripts/mesh.sh`**

Insert immediately before the `listen-wait)` case (`scripts/mesh.sh:548`), following the same `AS_ARGS`/`require_arg` conventions used by `listen-wait)` and `watch)`:
```bash
  listen)
    # Starts the `workbench-mesh listen` connector in the foreground — the
    # process `listen-wait`'s FIFO fast path depends on. Run this as a
    # long-lived background task (nohup/tmux/&) for it to have any effect;
    # it blocks until killed.
    if [ "${#AS_ARGS[@]}" -eq 0 ] && [ -z "${WORKBENCH_MESH_ACTOR:-}" ]; then
      echo "mesh: listen requires --as ACTOR (or export WORKBENCH_MESH_ACTOR)" >&2
      exit 2
    fi
    exec "$BIN" listen "${PROJECT_ARGS[@]}" "${AS_ARGS[@]}" "$@"
    ;;
```
Also add `listen` to the top-of-file `usage()` text alongside the existing `listen-wait` line (`scripts/mesh.sh:40`), e.g. directly above it:
```
  listen --as ACTOR         (starts the workbench-mesh listen connector in the foreground; run it backgrounded for listen-wait/inbox --wait to benefit from instant FIFO wake)
```

- [ ] **3. `start)` — validate `--bind` before printing the success banner, and document it**

Current relevant lines (`scripts/mesh.sh:298-302, 330-331`):
```bash
        --bind)
          require_arg "--bind value" "${2:-}"
          mode="$2"
          shift 2
          ;;
...
    print_start_info "$mode" "$port"
    exec "$BIN" serve "${PROJECT_ARGS[@]}" --bind "$mode" "${pass[@]}" "${AS_ARGS[@]}"
```
Add a shell-level allow-list check right where `--bind` is parsed, so an invalid mode fails before any banner is printed:
```bash
        --bind)
          require_arg "--bind value" "${2:-}"
          case "$2" in
            local|lan) mode="$2" ;;
            *) echo "mesh: --bind must be 'local' or 'lan' (got '$2')" >&2; exit 2 ;;
          esac
          shift 2
          ;;
```
Document `--bind` in `usage()` alongside `--lan`/`--local` (find the existing usage lines for those two flags in `scripts/mesh.sh`'s top `usage()` block and add a `--bind local|lan` line right after them, noting it's equivalent to `--local`/`--lan`).

- [ ] **4. Update `commands/mesh.md` for `listen` and `--bind`**

Add `listen` to the argument-hint (from Task 2's edit) in the same position as `listen-wait`, and add one line to the body noting `start --bind local|lan` is equivalent to `--local`/`--lan`. Re-read the current state of `commands/mesh.md` first (Task 2 will have already landed) before editing, to append rather than clobber.

- [ ] **5. Add test coverage**

In the mesh CLI test harness, add: (a) a case invoking `scripts/mesh.sh start --bind bogus` against a fresh temp project and asserting it exits non-zero with the `"--bind must be 'local' or 'lan'"` message *before* any "Workbench mesh will listen on" banner appears in the output; (b) a case invoking `scripts/mesh.sh listen --as someone` with no server running (or backgrounded briefly then killed) confirming the command reaches the Rust binary rather than erroring on argument parsing in the shell wrapper itself (a full connector lifecycle test is out of scope — just confirm the wrapper forwards correctly).

- [ ] **6. Run the suite and commit**

```bash
bash test/all.sh
git add scripts/mesh.sh commands/mesh.md test/<edited test file>
git commit -m "fix(mesh): add listen wrapper, validate --bind before the start banner"
```

---

### Task 5: connect error diagnostics reach the CLI (Rust)

**Files:**
- Modify: `crates/workbench-mesh/src/client.rs` (`accept_remote_invite`, ~line 195 per the original blocker report — re-locate exact function/line since B2's fix already touched this area)
- Test: `crates/workbench-mesh/src/client.rs` or `server.rs` inline `#[cfg(test)]` module (or `test/mesh-*.sh` if diagnostics are asserted at the CLI level)

**Context:** `redeem_invite` (`crates/workbench-mesh/src/auth.rs:683-714`) already produces three distinct messages ("invite not found" / "invite expired" / "invite exhausted") via `bail!`. The HTTP path wraps every `anyhow::Error` into the same `ApiError { status: BAD_REQUEST, message: error.to_string() }` (`server.rs:1002-1009`) — the `message` field itself IS the distinct string, so the question is purely whether the CLI's remote-accept path (`connect URL TOKEN` — the `--url` branch in `scripts/mesh.sh`'s `connect)` case) actually reads and prints that JSON body's `error` field, or discards it in favor of a generic "request failed: 400 Bad Request"-style message from the HTTP client library.

- [ ] **1. Investigate the actual remote-accept HTTP error path**

Read `crates/workbench-mesh/src/client.rs`'s HTTP-invite-accept function (the one `scripts/mesh.sh connect)`'s `--url` branch calls via `"$BIN" invite accept --url ...`). Find where it makes the POST request and handles a non-2xx response (likely a `reqwest::Response` with `.error_for_status()` or a manual `if !response.status().is_success()` check). Determine: does it currently just call `.error_for_status()?` (which produces a generic `"HTTP status client error (400 Bad Request)"` message and discards the JSON body), or does it already parse `{"error": "..."}` out of the body? Quote what you find in your implementation report.

- [ ] **2. Fix it to surface the real message**

If the current code discards the JSON body (the expected case, matching the audit's "generic, undiagnostic error" finding), change it to read the response body as JSON, extract the `error` field, and propagate it as the error message — e.g.:
```rust
if !response.status().is_success() {
    let status = response.status();
    let body: serde_json::Value = response.json().await.unwrap_or_default();
    let message = body.get("error").and_then(|v| v.as_str()).unwrap_or("request failed");
    anyhow::bail!("connect failed ({status}): {message}");
}
```
Adjust field/type names to match the actual surrounding code style (check how sibling functions in the same file already handle non-2xx responses, if any, and match that pattern rather than introducing a new one).

- [ ] **3. Write a test proving the three cases are distinguishable**

Add or extend a test (in `client.rs`'s test module if one exists, or `server.rs`'s, wherever HTTP invite-accept is already tested) that hits the real server with: an unknown token, an expired token (construct one with a past `expires_at`), and an exhausted token (one already at `max_uses`) — assert each produces a distinctly-worded error string (`.to_string()` contains "not found" / "expired" / "exhausted" respectively) at the client-facing level, not just internally in `auth.rs`.

- [ ] **4. Run tests and commit**

```bash
cd crates/workbench-mesh && cargo test
cd /home/guus/code/workbench && bash test/all.sh
git add crates/workbench-mesh/src/client.rs
git commit -m "fix(mesh): connect surfaces the real expired/exhausted/unknown-token reason"
```

---

### Task 6: lead.sh / level.md / supervise.md minor fixes

**Files:**
- Modify: `scripts/lead.sh:20-23` (`usage()`)
- Modify: `commands/level.md` (Single-dial override reachability)
- Modify: `commands/supervise.md:19-31` (`--session-id` parsing)
- Test: existing lead/level/supervise test coverage if any (`test/*.sh` — grep for `lead.sh`/`level`/`supervise` test files); otherwise verify by hand and note in the commit.

**Context:** Three small, unrelated maturity/orchestration-tooling docs and one script, each with a documented-but-unreachable or misleading behavior.

- [ ] **1. `scripts/lead.sh usage()` dumps raw source instead of a synopsis**

Current (`scripts/lead.sh:20-23`):
```bash
usage() {
  sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit "${1:-64}"
}
```
Replace with an actual usage synopsis covering the real subcommands (`set`, `status`, `latest-open`, `clear`) and flags (`--target`, `--as`/`--session-id`, `--mode`, `--purpose`, `--active-task`, `--track`) — read the rest of `scripts/lead.sh` first to confirm the exact subcommand/flag list and their meaning before writing the text:
```bash
usage() {
  cat >&2 <<'EOF'
usage: lead.sh <set|status|latest-open|clear> --target DIR [--as ID|--session-id ID] [options]

  set --target DIR --as ID --mode <task|track|backlog-scout|unassigned> --purpose "<text>" [--active-task ID] [--track NAME]
      Record this session's current lead purpose.
  status --target DIR --as ID
      Show the recorded purpose for this session.
  latest-open --target DIR
      Show the most recently recorded open (non-cleared) purpose.
  clear --target DIR --as ID
      Clear this session's recorded purpose.

--as is the canonical identity flag; --session-id is accepted as an alias.
EOF
  exit "${1:-64}"
}
```
(Confirm the exact subcommand names/flags against the real script before finalizing — do not invent a flag that doesn't exist.)

- [ ] **2. `commands/level.md` — make "Single-dial override" reachable**

Current `argument-hint` (`commands/level.md:4`): `"[status|up|down|<level>]"` — no flag routes to the "Single-dial override" section (lines 127-137). Add a documented flag and a dispatch branch. Read the file's existing dispatch structure (how it branches on `status`/`up`/`down`/`<level>`) and add a parallel branch for a new `override <dial> <value>` form:
```
argument-hint: "[status|up|down|<level>|override <dial> <value>]"
```
And in the body's dispatch section, add (matching the surrounding branches' style):
```
**`override <dial> <value>`:** jump straight to the "Single-dial override" section below with `<dial>`/`<value>` already parsed from `$ARGUMENTS` — skip the level status/up/down flow entirely.
```
Read the existing "Single-dial override" section (lines 127-137) to confirm it already expects a dial name + value as inputs (it does, per the research), so this dispatch branch just needs to feed those two parsed tokens into that existing section rather than rewriting it.

- [ ] **3. `commands/supervise.md` — actually parse `--session-id`**

Current body (`commands/supervise.md:19-31`) never extracts `--session-id <id>` from `$ARGUMENTS` even though `argument-hint` advertises it — the example command uses a literal placeholder the agent fills in by searching the session list. Fix the `status` and `install` sections to parse it when present, falling back to searching only when it's absent:
```
**`status` (default):** report whether a supervisor is configured and recent recovery activity:
[... existing bash block unchanged ...]
Then show the dry-run decision the supervisor would make right now. If `$ARGUMENTS` includes `--session-id <id>`, use that id directly; otherwise find the loop's session id from your Claude Code session list:
```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/watchdog.sh" --session-id "<loop-session-id>" --project "${CLAUDE_PROJECT_DIR}"
```
```
Apply the analogous change to the `install` paragraph: "If `$ARGUMENTS` supplies `--session-id <id>`, use it directly; otherwise the human supplies the loop's session id..."

- [ ] **4. Verify and commit**

Run whatever test coverage exists for these three scripts/docs (`grep -rl "lead.sh\|level.md\|supervise.md" test/`); if none exists, verify by hand: `scripts/lead.sh --help` should print the new synopsis, not source lines.
```bash
bash test/all.sh
git add scripts/lead.sh commands/level.md commands/supervise.md
git commit -m "fix: lead.sh usage synopsis, level.md dial-override routing, supervise.md --session-id parsing"
```

---

### Task 7: Dashboard chat-tick + audit-panel live-update

**Files:**
- Modify: `crates/workbench-mesh/assets/command-center/live.js` (`sendChat`, ~line 415-433; audit-append block, ~line 333-337)
- Modify: `crates/workbench-mesh/assets/command-center/bench.js` (`msgNode`, ~line 107; receipt handler, ~line 680-698 — read-only reference, likely unchanged)
- Modify: `crates/workbench-mesh/assets/command-center/host.js` (`renderAudit`, ~line 180-189; mount IIFE ~line 308)
- Test: `test/mesh-command-center-action-harness.js` / `test/mesh-command-center.test.sh` (the browser-action test harness used for prior mesh dashboard work — add or extend a case)

**Context:** Two related but distinct dashboard live-update gaps. (1) `sendChat`'s `.then()` backfills `m.seq` on the JS object but never updates the DOM row's `data-seq` attribute, so the receipt handler's `querySelector('.msg[data-seq="' + seq + '"]')` can never match the sender's own optimistic bubble — the tick only updates after a full re-render. (2) `host.js`'s `renderAudit` is only invoked on mount/tab-switch/local-operator-action; new audit events land in `WB.AUDIT` via the WS handler in `live.js` but nothing re-renders the panel, so it goes stale until the operator does something else that happens to trigger a re-render.

- [ ] **1. Fix `data-seq` backfill in `sendChat`**

Current (`live.js:415-433`):
```js
sendChat(m) {
  pendingSelf.push(m.text);
  const type = m.kind === 'ask' ? 'message.request_status' : m.kind === 'handoff' ? 'task.handoff' : 'message.sent';
  const payload = m.kind === 'handoff' ? { task_id: m.text } : { text: m.text };
  return post(type, m.room, payload, m.to || undefined).then((data) => {
    if (data && data.seq) {
      m.seq = data.seq;
      WB.RECEIPTS[data.seq] = WB.RECEIPTS[data.seq] || { deliveredBy: new Set(), seenBy: new Set() };
      WB.RECEIPTS[data.seq].serverReceivedAt = Date.now();
      sim.emit('receipt', data.seq);
    }
    return data;
  });
},
```
`sim.emit('receipt', data.seq)` already fires right after `m.seq` is set — the receipt handler in `bench.js` just can't find the row because its `data-seq` attribute is stuck at `""`. Fix by having the receipt handler (or this callback) update the DOM attribute once the seq is known. The cleanest fix is in `bench.js`'s receipt handler itself, since it already does the `querySelector` lookup — but that lookup is *why* it fails (it searches for the NEW seq, not the empty one). Instead, fix at the source: after `m.seq = data.seq;` in `sendChat`, also patch the DOM row that was optimistically rendered for this exact message object. Since `sendChat` (in `live.js`) doesn't have a reference to the DOM node `bench.js` created, the fix must either (a) pass the DOM node reference through, or (b) have `bench.js`'s `send()` register a callback/reference alongside the pushed message. Prefer (b) — it keeps `live.js` DOM-free (matching the existing separation where `live.js` is the API/protocol layer and `bench.js` owns rendering). In `bench.js`'s `send()` (~line 261-266), after appending the optimistic node, keep a reference and update its `data-seq` once `WB.api.sendChat(m)`'s promise resolves:
```js
const m = { room: room, who: 'you (operator)', kind: 'msg', text: t, ts: Date.now(), to: r.to || null, via: r.to ? null : r.via };
WB.CHAT.push(m);
const rm = WB.ROOMS.find((x) => x.id === room);
if (rm) rm.events += 1;
let node = null;
if (chatMatches(m)) { node = msgNode(m); scroll.appendChild(node); scroll.scrollTop = scroll.scrollHeight; }
if (WB.api) WB.api.sendChat(m).then(() => { if (node && m.seq != null) node.dataset.seq = String(m.seq); });
```
(Move the `if (chatMatches(m)) {...}` block above the `WB.api.sendChat(m)` call so `node` exists before the `.then()` closure captures it — check the exact current statement order in `bench.js` before editing, since the order shown here may already differ slightly from the file's real layout.)

- [ ] **2. Fix audit panel live-update in `host.js`**

Current WS append (`live.js:333-337`) only pushes into `WB.AUDIT`, never re-renders. Add a hook so `host.js` can react. The simplest approach matching the codebase's existing `sim.emit`/`sim.on` pattern (already used for `'receipt'`): emit an event when a new audit entry lands, and have `host.js` subscribe to it while the Host tab/audit panel is mounted.

In `live.js`, after the `WB.AUDIT.unshift(...)` line:
```js
if (/^(invite|device)\./.test(type) || type === 'decision.answer') {
  WB.AUDIT.unshift({ off: Math.max(0, Math.round((Date.now() - when) / 60000)), icon: railIcon[type] || 'shield', text: type + ' — ' + (p.role || p.device || p.decision || '') + ' by ' + displayWho(ev.from) });
  if (WB.AUDIT.length > 40) WB.AUDIT.pop();
  sim.emit('audit-update');
}
```
In `host.js`, find the mount IIFE (~line 308) that first calls `renderAudit(b)` for the audit panel body element — keep a reference to that body element in a module/closure-level variable (or reuse whatever pattern the file already has for referencing mounted panel bodies — check how `renderDevices`/`renderEnroll` are re-invoked elsewhere in the file, e.g. from `removeDevice`, for the existing convention) and subscribe once:
```js
WB.sim.on('audit-update', () => { if (auditBody && auditBody.isConnected) renderAudit(auditBody); });
```
Also add a periodic refresh (every 30s, only while the panel is mounted) so displayed timestamps keep advancing even with no new events — reuse whatever periodic-tick mechanism the file already has for other freshness indicators (grep `host.js` and `live.js` for `setInterval`/`sim.on('tick'` — the invite TTL countdown at `host.js:337-340` already listens to a `'tick'` event; hook the same event if the cadence is reasonable, e.g. ≤60s, rather than adding a second independent `setInterval`):
```js
WB.sim.on('tick', () => { if (auditBody && auditBody.isConnected) renderAudit(auditBody); });
```

- [ ] **3. Add a browser-action test case**

In `test/mesh-command-center-action-harness.js` (or the `.test.sh` driving it), add a scenario: open the Host tab, trigger an invite/device event from a second session (or synthetically dispatch the WS message the harness already uses for other live-update tests), and assert the audit panel DOM updates without any local operator action or tab switch. Model this on however the existing harness already tests other live-update paths (e.g. the chat receipt-tick tests from the original real-time-protocol work) — read a nearby existing test case for the harness's exact API shape before writing a new one.

- [ ] **4. Browser-verify by hand, run the suite, commit**

Since this is a live-DOM-update fix, actually run it in a browser (not just unit-test the JS in isolation) per this repo's established practice for dashboard changes — start a local mesh server, open two dashboard sessions, send a chat message from one and confirm its own tick updates in place without a reload; trigger an invite/device event and confirm the audit panel updates live in the other session.
```bash
bash test/all.sh
git add crates/workbench-mesh/assets/command-center/live.js crates/workbench-mesh/assets/command-center/bench.js crates/workbench-mesh/assets/command-center/host.js test/mesh-command-center-action-harness.js
git commit -m "fix(mesh): backfill data-seq on send, live-update the audit panel"
```

---

### Task 8: Dashboard invite-list timing + availability/activity validation & mislabel

**Files:**
- Modify: `crates/workbench-mesh/assets/command-center/host.js` (`createInvite`, ~line 140-159)
- Modify: `crates/workbench-mesh/assets/command-center/bench.js` (`renderTypingLine`, ~line 638-653)
- Modify: `crates/workbench-mesh/src/main.rs` (`ActivityArgs`, ~line 396-410; find and check `AvailabilityArgs` alongside it)
- Modify: `crates/workbench-mesh/src/client.rs` (`set_activity`, ~line 555-591; the availability equivalent)
- Test: `crates/workbench-mesh/src/` inline tests for the Rust validation; browser/manual check for the JS fixes.

**Context:** Three related dashboard-facing gaps. (1) A newly-created invite isn't pushed into `WB.INVITES` until the operator clicks Copy, even though the server already created it — so the countdown/list is wrong until then. (2) Neither `activity` nor `availability` validates its state string anywhere (CLI or server), so arbitrary free text flows all the way to the dashboard. (3) `renderTypingLine` in `bench.js` assumes any non-`'typing'` truthy activity means "reading," mislabeling e.g. a hypothetical future state or malformed input as "reading."

- [ ] **1. Push the invite into `WB.INVITES` on the successful POST, not on Copy**

Current (`host.js:140-159`):
```js
function createInvite(body, role, ttlLabel) {
  const ttlSeconds = ttlLabel === '2h' ? 7200 : 1800;
  if (!WB.api) return;
  WB.api.createInvite(role, ttlSeconds).then((data) => {
    const token = data.token;
    const id = 'inv-' + token.slice(0, 6);
    const box = el('div', {}, [
      el('div', { class: 'inv-token' }, [
        el('code', { text: token }),
        el('button', { class: 'btn', style: 'font-size:11px; flex-shrink:0;', html: svgIcon('copy', 11) + ' Copy', onclick: () => {
          navigator.clipboard && navigator.clipboard.writeText(token);
          WB.INVITES.push({ id: id, role: role, ttl: ttlSeconds, createdBy: 'you', token: token });
          toast('Token copied — it will not be shown again');
          renderEnroll(body);
        } }),
      ]),
      el('div', { class: 'inv-token-note', text: 'Shown exactly once. The server keeps only a one-way hash — copy it now.' }),
    ]);
    body.appendChild(box);
  }).catch((err) => toast('Invite failed: ' + err.message));
}
```
Move the `WB.INVITES.push(...)` out of the Copy button's `onclick` and into the `.then((data) => ...)` continuation, right after computing `id`:
```js
function createInvite(body, role, ttlLabel) {
  const ttlSeconds = ttlLabel === '2h' ? 7200 : 1800;
  if (!WB.api) return;
  WB.api.createInvite(role, ttlSeconds).then((data) => {
    const token = data.token;
    const id = 'inv-' + token.slice(0, 6);
    WB.INVITES.push({ id: id, role: role, ttl: ttlSeconds, createdBy: 'you', token: token });
    const box = el('div', {}, [
      el('div', { class: 'inv-token' }, [
        el('code', { text: token }),
        el('button', { class: 'btn', style: 'font-size:11px; flex-shrink:0;', html: svgIcon('copy', 11) + ' Copy', onclick: () => {
          navigator.clipboard && navigator.clipboard.writeText(token);
          toast('Token copied — it will not be shown again');
          renderEnroll(body);
        } }),
      ]),
      el('div', { class: 'inv-token-note', text: 'Shown exactly once. The server keeps only a one-way hash — copy it now.' }),
    ]);
    body.appendChild(box);
  }).catch((err) => toast('Invite failed: ' + err.message));
}
```
Note the Copy button's `onclick` no longer needs to call `renderEnroll(body)` for the sake of registering the invite (that already happened) — check whether `renderEnroll` is still needed there for some other reason (e.g. refreshing the active-invites list display) before deciding whether to keep or drop that call; if the invite list section elsewhere reads from `WB.INVITES` reactively already, keeping the `renderEnroll(body)` call is still correct so the newly-pushed invite becomes visible in that list immediately (right after the POST, not gated on Copy).

- [ ] **2. Add allow-list validation for `activity` and `availability` state values**

Read `crates/workbench-mesh/src/main.rs` around `ActivityArgs` (~line 396-410) and find `AvailabilityArgs` (search nearby) to see if it already validates. Based on research, `ActivityArgs.state` is a bare `String` with only a doc comment (`/// reading | typing | idle`) — no enum, no allow-list. Add validation for both at the point where the CLI constructs the outgoing event, rejecting unknown values with a clear error rather than a clap-level type change (clap enums would break scripts passing values it doesn't yet know about; use a runtime check instead so the error message stays clear and controllable). In `client.rs`'s `set_activity` (~line 555-591), add a check before building the payload:
```rust
const VALID_ACTIVITY_STATES: &[&str] = &["typing", "reading", "idle"];
if !VALID_ACTIVITY_STATES.contains(&state.as_str()) {
    anyhow::bail!(
        "invalid activity state '{state}' — must be one of: {}",
        VALID_ACTIVITY_STATES.join(", ")
    );
}
```
Apply the equivalent to the `availability`-setting function alongside it, using whatever the dashboard's own allow-list actually is (check `bench.js`/`ops.js`/wherever availability chips are rendered for the exact set of recognized values — likely `online`/`away`/`busy` or similar; do not invent values not already recognized by the dashboard).

- [ ] **3. Fix the `renderTypingLine` mislabel**

Current (`bench.js:638-653`):
```js
for (const { a, act } of engaged) {
  const n = leadName(a.id);
  n.style.fontWeight = '600';
  line.appendChild(el('span', { class: 'tl-item' }, [
    pulse(WB.eff.heat(a)),
    n,
    el('span', { text: ' is ' + (act === 'typing' ? 'typing…' : 'reading') }),
  ]));
}
```
Since Task 8-2 above now guarantees `act` can only ever be `'typing'`/`'reading'`/`'idle'` (validated server-side), this fallback is technically safe post-fix — but keep the JS defensive anyway (a stale/older client could still receive an unvalidated value from a server that hasn't been upgraded yet), and make the fallback show the actual value instead of assuming "reading":
```js
    el('span', { text: ' is ' + (act === 'typing' ? 'typing…' : act === 'reading' ? 'reading' : WB.ui.esc(act)) }),
```

- [ ] **4. Test and commit**

```bash
cd crates/workbench-mesh && cargo test
cd /home/guus/code/workbench && bash test/all.sh
git add crates/workbench-mesh/assets/command-center/host.js crates/workbench-mesh/assets/command-center/bench.js crates/workbench-mesh/src/main.rs crates/workbench-mesh/src/client.rs
git commit -m "fix(mesh): invite appears on create not on copy; validate activity/availability states"
```

---

### Task 9: watch blank-bubble content fix + nonexistent-target warning

**Files:**
- Modify: `crates/workbench-mesh/src/client.rs` (`watch_actor`, ~line 660-678; `send_message`/`ask_status`, ~line 323-363)
- Test: `crates/workbench-mesh/src/` inline tests

**Context:** Per this plan's Global Constraints, both fixes here are scoped as non-blocking (a warning, not a hard reject) because no actor-registration step exists — see the constraints section for why a hard existence gate would break legitimate first-contact messages.

- [ ] **1. Give `watch` a real, visible text payload**

Current (`client.rs:660-678`, excerpt):
```rust
let event = append_or_post_event(
    &project_root, home, "message.sent", &room_for_target(&actor),
    &resolve_actor(from.as_deref()), Some(&actor),
    json!({ "intent": "watch", "actor": actor }),
).await?;
```
The payload has no `text` field, so the dashboard's ingest (`live.js:238-246`, `const text = p.text || p.question || (p.task_id ? ... : '')`) falls through to an empty string and renders a blank bubble. Add a `text` field to the payload:
```rust
let event = append_or_post_event(
    &project_root, home, "message.sent", &room_for_target(&actor),
    &resolve_actor(from.as_deref()), Some(&actor),
    json!({ "intent": "watch", "actor": actor, "text": format!("is checking in on {actor}'s work") }),
).await?;
```
Confirm the exact wording reads sensibly given `resolve_actor(from.as_deref())` is the one doing the watching, not `actor` — adjust the message to read naturally from the recipient's point of view (e.g. "someone is watching your work" vs "is checking in on {actor}'s work" — pick whichever matches how other system-generated message text in this file is phrased; check `handoff_task`'s or a similar payload's text convention for the established voice).

- [ ] **2. Add a non-blocking warning for sends to a never-seen actor**

Add a small helper that checks whether `to` has any prior history in the event log (reuse the same query `state_json` uses — `crates/workbench-mesh/src/server.rs:802-812`'s `actors` `BTreeSet` construction logic, or expose a small helper function from `store.rs` that both can call instead of duplicating the scan). This is CLI-side (client.rs), so it needs to either call the server's `/api/state` (if in remote/lan mode) or scan the local store directly (if local mode) — check how other client.rs functions already decide local-vs-remote dispatch (e.g. `send_message`'s existing local/remote branching) and follow the same pattern. After the event is successfully posted (do not block the send on this check — do it as a best-effort follow-up, and never fail the command if the check itself errors):
```rust
// Best-effort: if `to` has no prior history in this mesh's events, warn —
// but never block the send. There's no actor-registration step, so a hard
// reject here would break the first legitimate message to a brand-new actor.
if let Ok(known) = known_actors(&project_root, home.as_deref()).await {
    if !known.contains(&to) {
        eprintln!("mesh: note — '{to}' has no prior activity in this mesh; double-check the name");
    }
}
```
Apply this same best-effort warning to `send_message`, `ask_status`, and `watch_actor` (all three target an actor by name). Extract `known_actors(...)` as a shared helper (in `client.rs` or a shared module) rather than duplicating the state-fetch/scan logic three times.

- [ ] **3. Write tests**

Add a test confirming `watch`'s posted event payload now includes a non-empty `text` field. Add a test confirming the nonexistent-actor warning fires (capture stderr, or check the function returns success while a captured warning message is present) for a `to` never seen before, and does NOT fire for a `to` that has prior history — and confirm in both cases the send itself still succeeds (this is the core regression this task must not introduce: a false-positive warning must never become a false-negative block).

- [ ] **4. Run tests and commit**

```bash
cd crates/workbench-mesh && cargo test
cd /home/guus/code/workbench && bash test/all.sh
git add crates/workbench-mesh/src/client.rs
git commit -m "fix(mesh): watch posts visible text; warn (non-blocking) on sends to an unseen actor"
```

---

### Task 10: Handoff room consistency + receipt-tick 4-state CSS + channel-bridge ack filter (+ test)

**Files:**
- Modify: `crates/workbench-mesh/src/client.rs` (`handoff_task`, ~line 365-379) — or `bench.js`'s `handOff` function, whichever direction the fix takes (see step 1)
- Modify: `crates/workbench-mesh/assets/command-center/bench.js` (`handOff`, ~line 585-598)
- Modify: `crates/workbench-mesh/assets/command-center/style-surfaces.css` (`.tick`/`.tick-seen`/`.tick-delivered`, ~line 386-395)
- Modify: `scripts/mesh-channel.js:90` (event-type filter)
- Test: `test/mesh-channel-driver.js` (add `message.delivered`/`message.read` fixture events), `test/mesh-channel.test.sh`

**Context:** Four related-but-separable Important findings, grouped here because they're each a small, focused fix and three of them touch the messaging/delivery layer.

- [ ] **1. Fix the CLI-handoff vs dashboard-Hand-Off room/`to` mismatch**

CLI hardcodes room `"tasks"` and sets `to` (`client.rs:365-379`); dashboard posts to `a.room` (the agent's last-active room) with no `to` (`bench.js:585-598`, via `WB.api.post('task.handoff', a.room, {...})` with only 3 args). There is no shared constant today (confirmed: `"tasks"` is hardcoded independently in 3 places — `client.rs:376`, `live.js:448`, `live.js:451` — and the dashboard's Hand Off path doesn't even use that literal). Make the dashboard match the CLI's convention (room `"tasks"`, with `to` set to the target), since the CLI is the documented/authoritative path and `wb-coord`'s claim flow (mentioned in the dashboard's own confirm-dialog body text: "the receiving session claims via wb-coord before it starts") already expects a room both paths can agree on:

In `bench.js`'s `handOff` (~line 585-598), change the `WB.api.post` call to pass `'tasks'` as the room and the target as `to`:
```js
onConfirm: () => {
    const m = { room: 'tasks', who: 'you (operator)', kind: 'handoff', text: (t ? t.id + ' ' : '') + '→ next available session', ts: Date.now(), to: a.id };
    WB.CHAT.push(m);
    if (WB.api) WB.api.post('task.handoff', 'tasks', { task_id: t ? String(t.id) : a.doing }, a.id);
    toast('Handoff posted to tasks', 'mesh handoff' + (t ? ' ' + t.id : ''));
},
```
Verify `WB.api.post`'s signature (`live.js:404-411`, `function post(type, room, payload, to)`) already accepts a 4th `to` argument — confirmed by research, so this is a drop-in change. Double-check whether any other code reads `m.room` expecting it to equal `a.room` for handoff-kind messages specifically (grep `kind === 'handoff'` across the JS) before finalizing, since changing the pushed `WB.CHAT` object's `room` field to `'tasks'` could affect what room the handoff bubble renders under in the chat view — if that's undesirable (the operator expects to see the handoff message in the agent's own room, not jump to "tasks"), keep `m.room: a.room` for the **client-side rendered bubble** but still pass `'tasks'` as the room argument to `WB.api.post` (the two don't have to match — the local optimistic bubble can render wherever's most useful, while the actual posted event uses the canonical handoff room). Use judgement here and document the choice in your implementation report.

Extract the `"tasks"` literal into one shared reference if practical (e.g. a `const HANDOFF_ROOM = 'tasks';` near the top of `live.js`, imported/referenced by `bench.js`'s handoff call — check whether these files already share constants via a `WB.constants`-style object or similar, and follow that convention if it exists, otherwise a simple top-of-file const in `live.js` referenced as `WB.HANDOFF_ROOM` is fine).

- [ ] **2. Distinguish all 4 receipt-tick states visually**

Current CSS (`style-surfaces.css:386-395`):
```css
.tick {
  margin-left: 6px;
  font-size: 11px;
  letter-spacing: -1px;
  color: var(--ink-3, #8a8f98);
}
.tick-seen, .tick-delivered {
  color: var(--amber-deep, #b8860b);
}
```
`tick-sent`/`tick-received` share identical styling+glyph (`✓`, base `.tick` color) and `tick-seen`/`tick-delivered` share identical styling+glyph (`✓✓`, amber). Give each of the 4 classes distinct styling. Read the file's existing color token names (`--ink-3`, `--amber-deep`, and check for a couple more nearby, e.g. a muted/faint variant and a stronger "success" or "read" tone) before picking values — reuse existing tokens rather than inventing new hex colors where a fitting token already exists:
```css
.tick {
  margin-left: 6px;
  font-size: 11px;
  letter-spacing: -1px;
}
.tick-sent { color: var(--ink-4, #b3b8c0); }
.tick-received { color: var(--ink-3, #8a8f98); }
.tick-delivered { color: var(--amber-deep, #b8860b); }
.tick-seen { color: var(--amber-deep, #b8860b); font-weight: 600; }
```
(`tick-sent` lighter/fainter than `tick-received` reflects "not yet acknowledged by the server" vs "server has it"; `tick-seen` bolded relative to `tick-delivered` gives a stronger visual cue for "read" vs merely "delivered" while keeping the same hue family, since the glyph difference `✓` vs `✓✓` already carries most of the sent/received-vs-delivered/seen distinction — the fix here specifically closes the *within-pair* ambiguity the audit flagged.) Adjust color values to whatever tokens actually exist in the stylesheet's `:root` — do not invent `--ink-4` if it doesn't already exist; check first and either reuse a real token or add one consistent with the existing naming scheme.

- [ ] **3. Fix the channel-bridge's overly-broad event-type filter**

Current (`scripts/mesh-channel.js:90`):
```js
if (!/^(message\.|task\.handoff)/.test(e.type || "")) continue;
```
This matches `message.delivered`/`message.read` (ack types) even though they're only excluded today by the accidental side effect of having an empty payload (line 99-101's `text` check). Make the exclusion explicit and no longer dependent on payload shape:
```js
if ((e.type || "") === "message.delivered" || (e.type || "") === "message.read") continue;
if (!/^(message\.|task\.handoff)/.test(e.type || "")) continue;
```

- [ ] **4. Add a regression test for the ack-event exclusion**

In `test/mesh-channel-driver.js` (~line 73-77), add fixture events for both ack types:
```js
JSON.stringify({ seq: 7, type: "message.delivered", room: "repo:demo", from: "test-lead", ack_of: 2, payload: {} }),
JSON.stringify({ seq: 8, type: "message.read", room: "repo:demo", from: "test-lead", ack_of: 2, payload: {} }),
```
In `test/mesh-channel.test.sh`, add an assertion that neither seq 7 nor seq 8 produces a bridged-out message (check however the existing test confirms exclusion for other filtered event types, e.g. the self-chat/allowlist cases at seq 3/5, and mirror that assertion style).

- [ ] **5. Run tests and commit**

```bash
bash test/mesh-channel.test.sh
bash test/all.sh
git add crates/workbench-mesh/src/client.rs crates/workbench-mesh/assets/command-center/bench.js crates/workbench-mesh/assets/command-center/style-surfaces.css scripts/mesh-channel.js test/mesh-channel-driver.js test/mesh-channel.test.sh
git commit -m "fix(mesh): unify handoff room/to, distinguish all 4 receipt-tick states, explicit ack-event bridge exclusion"
```

---

### Task 11: DM-privacy docs honesty + "no response yet" 30s hint

**Files:**
- Modify: `skills/mesh/SKILL.md` and/or `commands/mesh.md` (DM privacy wording)
- Modify: `crates/workbench-mesh/assets/command-center/bench.js` (per-message stuck-detection timer/hint)
- Modify: `crates/workbench-mesh/assets/command-center/style-surfaces.css` (hint styling, if needed)
- Test: `test/mesh-command-center-action-harness.js` (add a case)

**Context:** Two Important findings bundled because both concern message-delivery honesty in the UI/docs.

- [ ] **1. Make DM-privacy docs honest (per Global Constraints scoping)**

Grep `skills/mesh/SKILL.md` and `commands/mesh.md` for any phrasing implying `message <actor>` is private/direct in a security sense (e.g. "direct message", "private"). Where found, add or adjust wording to state the real model plainly — e.g., near wherever `message`/`ask` targeting-by-actor-name is documented:
```
Note: targeting a message at an actor name (rather than a room) routes it to a room named after that actor — this is a convenience for 1:1-style conversations, not a security boundary. Any session holding this project's mesh credential can read any room, including these. There is no per-room access control today.
```
Place this note adjacent to the existing `message`/`ask` documentation in both files (wherever the "direct" framing currently appears), not as a new standalone section.

- [ ] **2. Implement the "no response yet" 30s hint**

Spec (`docs/superpowers/specs/2026-07-03-mesh-realtime-protocol-design.md:90,111`): a message stuck at "server-received" with no `message.delivered` within ~30s should surface a "no response yet" hint. Implement in `bench.js` near the receipt-tick rendering (`receiptGlyph`, ~line 70-78) and wherever sent messages are tracked (`WB.RECEIPTS`). Add a per-message timer set when a message reaches `serverReceivedAt` (i.e. right when `sendChat`'s `.then()` sets it — hook into the same `sim.on('receipt', ...)` handler in `bench.js` that already reacts to this transition, rather than adding a second listener):
```js
WB.sim.on('receipt', (seq) => {
  const r = WB.RECEIPTS[seq];
  if (r && r.serverReceivedAt && !r.deliveredBy.size && !r._stuckTimer) {
    r._stuckTimer = setTimeout(() => {
      if (!r.deliveredBy.size && !r.seenBy.size) {
        r.stuck = true;
        const row = document.getElementById('chat-scroll')?.querySelector('.msg[data-seq="' + seq + '"]');
        if (row) row.appendChild(el('span', { class: 'stuck-hint', title: 'no response yet — the recipient’s listen connector may be down', text: ' ⚠' }));
      }
    }, 30000);
  }
  // ... existing tick-update logic below, unchanged
});
```
Clear the timer (`clearTimeout(r._stuckTimer)`) if delivery/read does arrive before 30s, to avoid a stale hint appearing after the fact — check this against the existing receipt-handling flow (delivered/read events likely already update `r.deliveredBy`/`r.seenBy` elsewhere in this same handler or a related one; find that code and add the `clearTimeout` there too). Add a minimal `.stuck-hint` CSS rule (small, muted warning color, matching the file's existing token conventions) if the inline styling above isn't sufficient on its own.

Since `data-seq` for the sender's own optimistic bubble wasn't reliably queryable before Task 7's fix, this task depends on Task 7 landing first (same `querySelector('.msg[data-seq=...]')` pattern) — sequence Task 11 after Task 7.

- [ ] **3. Add a test case and browser-verify**

In the action-test harness, simulate a message reaching `serverReceivedAt` with no delivery event following within the test's accelerated/mocked timer window, and assert the `.stuck-hint` element appears; simulate a second message where delivery arrives promptly and assert no hint appears. If the harness doesn't support mocking `setTimeout`/fake timers, browser-verify by hand instead (send a message to an actor with no `listen` connector running, wait 30s, confirm the hint appears) and note that in the report rather than skipping verification entirely.

- [ ] **4. Run the suite and commit**

```bash
bash test/all.sh
git add skills/mesh/SKILL.md commands/mesh.md crates/workbench-mesh/assets/command-center/bench.js crates/workbench-mesh/assets/command-center/style-surfaces.css test/mesh-command-center-action-harness.js
git commit -m "docs(mesh): honest DM-privacy wording; feat(mesh): 30s no-response-yet hint"
```

---

### Task 12: Docs-consistency batch (11 minor findings)

**Files:**
- Modify: `commands/init.md`, `commands/boot.md`, `commands/doctor.md`, `commands/workbench.md`, `commands/task.md`, `commands/next.md`, `commands/decision.md`, `templates/schemas/config.schema.json`, `commands/epic.md` (or `scripts/epic-close.sh`), `commands/lead.md`, `commands/teamlead.md`, `docs/commands.md`
- Test: `bash test/all.sh` (run full suite; add one assertion for the epic-close zero-task case, see step 9)

- [ ] **1. `commands/init.md` — ask about `--hooks` in the bare-invocation wizard**

Current wizard clause (`init.md:10`) only asks name/mission/launch/level. Add a hooks question matching `setup.md:8`'s pattern:
```
Parse `$ARGUMENTS`. If `--name` is not present (or the command was invoked bare), don't fail or dump usage — run a short wizard: use AskUserQuestion for the project name (offer the repo directory name as the default candidate), whether to enable Workbench hooks (Recommended) or skip them (less benefit; slash commands still work), optionally a one-line mission and launch target, then the level per step 2; confirm the assembled `init.sh` invocation before running it.
```

- [ ] **2. `commands/boot.md` / `commands/doctor.md` — cross-reference the duplicated health checks**

Both files independently describe the in-review cap check, phantom-lane reap, and drift/upgrade recommendation. Add one cross-reference line to each rather than deduplicating the content (both commands need to remain independently runnable): in `boot.md`, after its in-review-cap/phantom-lane/drift checks, add: `"(These same checks live in more detail in \`/workbench:doctor\` — this is boot's abbreviated pass.)"`. In `doctor.md`, add: `"(\`/workbench:boot\` runs an abbreviated version of these same checks as part of session start.)"`.

- [ ] **3. Argument-hint style — standardize on omission for no-arg commands**

`doctor.md:4` has `argument-hint: ""`; `boot.md`/`setup.md`/`upgrade.md` omit the field entirely for the same no-arg case. Remove the `argument-hint: ""` line from `doctor.md`'s frontmatter to match the other three (omission, not an explicit empty string).

- [ ] **4. `commands/workbench.md` — scope the auto-defer claim**

Current (`workbench.md:14`): "any `/workbench:*` command, when run in an unconfigured project, should defer to this front-door assessment." Since `dispatch.md` (and others) don't implement this, either (a) soften the claim to describe intent rather than universal behavior, or (b) note it's aspirational. Prefer (a) — rewrite to: `"This is also intended as the fallback for any \`/workbench:*\` command run in an unconfigured project — not every command implements this defer-check yet; treat this doc as the front door to point users at manually when you notice a command running against an unconfigured project."`

- [ ] **5. `commands/task.md` — add `--repos` to the guided wizard**

Current wizard (`task.md:17`) asks epic/track/estimate but not repos. Add it:
```
Treat `$ARGUMENTS` as the task title (plus any optional `--epic` / `--track` / `--repos` / `--estimate` the user passed). If no title is present, don't fail or dump usage — run a short wizard: use AskUserQuestion for a one-line title, then (optionally) epic / track / repos / estimate, offering discovered candidates as options (open epic IDs from `.claude/epics/`, existing `**Track:**` values in the backlog, previously-used repo names if any are recorded); confirm the assembled `task-new.sh` invocation, then run it.
```

- [ ] **6. `commands/next.md` — define the zero-candidates output**

Add a fourth branch after the existing cap/blocked/ready-task cases (~after line 18): `"5. If \`deps.sh ready\` returns zero candidates, say so plainly — distinguish an empty backlog (\"no backlog tasks exist yet — run /workbench:task to add one\") from everything-blocked (\"N backlog tasks exist but all are blocked — check \`deps.sh cycles\` for a dependency loop, or see which Blocked-by hasn't landed\")."` Update the closing summary line (~line 21) to include this as a fourth valid output reason alongside cap/drain, blocked/dependency, ready task.

- [ ] **7. `commands/decision.md` — wire up `--context` or drop it from argument-hint**

Since `--context` is never parsed anywhere, the honest minimal fix is to make the wizard actually use it when present rather than leaving it a dead flag. Add to the body (~line 13): `"If \`$ARGUMENTS\` includes \`--context <summary>\`, use that text directly as the decision's context/notes field rather than deriving one from conversation; otherwise derive it as described below."` Confirm the decision-creation script (`task-new.sh`-adjacent, whatever `decision.md` actually invokes) has a field to receive this context text before finalizing the wording — if no such field exists in the underlying script, note that as a NEEDS_CONTEXT item in your report rather than inventing a script change out of scope for a docs task.

- [ ] **8. `templates/schemas/config.schema.json` — add `cross_model_verification`**

Add the missing key to both `properties` and `required` in the `way_of_working` object (~lines 41-52), matching the existing enum style. Check `verify.md`/wherever else `cross_model_verification` is read for its actual valid values (likely `on`/`off` per `verify.md:14`'s phrasing "When... is `on`... When it's off...") before picking the enum:
```json
"cross_model_verification": { "enum": ["on", "off"] }
```
Add `"cross_model_verification"` to the `required` array (~line 41) alongside the existing 10 keys.

- [ ] **9. `scripts/epic-close.sh` — warn on zero-linked-tasks close**

Current (`epic-close.sh:64-102`) closes silently with a "0/0 linked task(s) verified terminal" note when `linked_files` is empty. Add an explicit warning line (not a hard failure — the audit calls this "undocumented vacuous-success," not "wrong behavior," so keep the close succeeding but make it visible):
```bash
if [ "$nlinked" -eq 0 ]; then
  echo "epic-close: warning — $ID has zero linked tasks (closing anyway; is this the epic you meant?)" >&2
fi
```
Insert this check right after the `nlinked`/`nblocking` computation (~line 66-67), before the `nblocking -gt 0` gate. Add a test case in whichever test file already covers `epic-close.sh` (grep `test/` for it) asserting this warning line appears on stderr for a freshly-created epic with no linked tasks.

- [ ] **10. `commands/lead.md` / `commands/teamlead.md` — switch to `--as`**

Replace every `--session-id "<session-id>"` occurrence in both files with `--as "<session-id>"` (3 occurrences in `lead.md`: lines 16, 36, 59; 1 in `teamlead.md`: line 13) — `lead.sh` already treats `--as` as canonical (`scripts/lead.sh:31-32`) and accepts `--session-id` only as a compatibility alias, so this is a pure rename with no behavior change.

- [ ] **11. `docs/commands.md` — add the missing `/workbench:claude-engineer` entry**

Insert a new `###` entry between the `/workbench:dispatch` entry (~line 60) and the `/workbench:codex-engineer` entry (~line 62), mirroring the latter's format:
```
### `/workbench:claude-engineer <id> [--worktree [name]|--shared] [--background|--wait] [lane/repo]`
Move an explicit unblocked task to `in-development/` and dispatch it to a native Claude engineer lane — the default engine `/workbench:dispatch` routes to. Claims via `wb-coord`, resolves the model via the `models` skill, and spawns the `engineer` Task-tool lane (foreground, `--worktree`, `--background`/`--wait`, or `--shared`).
```
Adjust wording to match `commands/claude-engineer.md`'s actual current argument-hint and behavior exactly (re-read the file, including Task 1's edits to it, before finalizing this entry) rather than copying `codex-engineer`'s wording verbatim.

- [ ] **12. Run the full suite and commit**

```bash
bash test/all.sh
git add commands/init.md commands/boot.md commands/doctor.md commands/workbench.md commands/task.md commands/next.md commands/decision.md templates/schemas/config.schema.json scripts/epic-close.sh commands/lead.md commands/teamlead.md docs/commands.md test/<epic-close test file>
git commit -m "docs: 11 command-doc consistency fixes (hooks wizard, cross-refs, --repos, cross_model_verification, --as, claude-engineer entry)"
```

---

### Task 13: Dashboard minor batch (devices empty-state, form ids, Ops dead-space, room guard, keyboard access)

**Files:**
- Modify: `crates/workbench-mesh/assets/command-center/host.js` (`renderDevices`, ~line 203-226; room-creation handler)
- Modify: `crates/workbench-mesh/assets/command-center/bench.js` (chat composer input, ~line 184, ~line 506)
- Modify: `crates/workbench-mesh/assets/command-center/ops.js` (task-reassign input, ~line 148)
- Modify: `crates/workbench-mesh/assets/command-center/style-surfaces.css` (`.ops-main`, ~line 250-254)
- Modify: `crates/workbench-mesh/assets/command-center/docs.js` (`.rung` element ~line 131-134, `.cmd-item` ~line 342)
- Test: `bash test/all.sh`; manual browser check for the CSS/accessibility items (no meaningful automated assertion for a `max-width`/`margin` centering fix or a keyboard-focus check without a fuller a11y test harness — note this in the report rather than fabricating a shallow test)

**Context:** Five small, independent dashboard polish items.

- [ ] **1. Devices table empty state**

Current (`host.js:203-226`) has no zero-devices branch. Add one, matching `renderEnroll`'s existing pattern (`host.js:124`, `if (!WB.INVITES.length) list.appendChild(el('div', {...text: 'No active invites.'}))`):
```js
function renderDevices(body) {
  body.replaceChildren();
  if (!WB.DEVICES.length) {
    body.appendChild(el('div', { class: 'empty-state', text: 'No enrolled devices yet.' }));
    return;
  }
  const table = el('table', { class: 'wb' });
  ...
}
```
Check whether an `.empty-state` CSS class already exists (likely, given the invites list uses similar language) — reuse it rather than adding a new one.

- [ ] **2. Add `id`/`name` to the 4 identified form fields**

- `bench.js:184` (team chat composer textarea): add `id: 'chat-compose-input', name: 'chat-message'`.
- `bench.js:506` (focus-view composer textarea): add `id: 'focus-compose-input', name: 'focus-message'`.
- `host.js:117-118` (role/TTL selects): add `id: 'invite-role', name: 'invite-role'` and `id: 'invite-ttl', name: 'invite-ttl'` respectively.
- `ops.js:148` (task-reassign id input): add `id: 'reassign-task-id', name: 'reassign-task-id'`.
Use distinct, unique ids across the file (check neither `bench.js` id collides with anything already using `chat-compose-input`, etc. — grep first).

- [ ] **3. Fix Ops tab dead space on wide viewports**

Current (`style-surfaces.css:250-254`):
```css
.ops-main { flex: 1; min-width: 0; overflow-y: auto; padding: var(--space-lg) var(--space-xl); display: flex; flex-direction: column; gap: 14px; }
.ops-main .panel { max-width: 880px; }
```
Center the capped-width panels instead of leaving them hugging the left edge:
```css
.ops-main { flex: 1; min-width: 0; overflow-y: auto; padding: var(--space-lg) var(--space-xl); display: flex; flex-direction: column; align-items: center; gap: 14px; }
.ops-main .panel { max-width: 880px; width: 100%; }
```
(`align-items: center` on the flex column centers each child horizontally; `width: 100%` on `.panel` ensures it still fills up to its `max-width` cap rather than shrinking to content width first.) Browser-verify at a wide viewport (≥1600px) that panels are now centered with even space on both sides, not just empty space on the right.

- [ ] **4. Room-creation duplicate/reserved-name guard**

Current (`client.rs:303-321`, `create_room`) accepts any name unchecked. Add a check against the two known reserved names (`team`, `tasks`) at minimum, and check for an existing room with the same name (query however `state_json`/the store already lists rooms — check `store.rs` for a room-listing helper, or derive from the same events scan used elsewhere) before creating:
```rust
const RESERVED_ROOMS: &[&str] = &["team", "tasks"];
if RESERVED_ROOMS.contains(&name.as_str()) {
    anyhow::bail!("'{name}' is a reserved room name (used internally for {}); choose a different name", RESERVED_ROOMS.join("/"));
}
```
For the duplicate check, decide based on what's actually cheap to query here — if a full room-existence check requires scanning all events (no dedicated room registry), a lightweight approach is acceptable: check whether any existing event already has this exact `room` value, and if so, warn (non-blocking, similar to Task 9's pattern) rather than hard-reject, since "room already exists" isn't necessarily an error (re-creating/re-joining an existing room by name is arguably fine) — but reserved names should hard-reject. Use judgement and note the choice made in your report.

- [ ] **5. Docs tab keyboard accessibility for click-to-activate elements**

Current (`docs.js:131-134` maturity rung, `docs.js:342` command-palette row) use plain `div`s with `onclick`. Add keyboard support by giving them `tabindex="0"`, `role="button"`, and a `keydown` handler that fires on Enter/Space — check the `el()` helper (`ui.js:4-18`) supports an `onkeydown`-style attr (it should, given it does generic `addEventListener` dispatch for any `on*` key) before writing this:
```js
return el('div', {
  class: 'rung' + (isCur ? ' current' : '') + (isPrev ? ' previewing' : ''),
  tabindex: '0',
  role: 'button',
  onclick: () => { previewTarget = isCur ? null : id; rerender(); },
  onkeydown: (e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); previewTarget = isCur ? null : id; rerender(); } },
}, [
```
Apply the same pattern to the `docs.js:342` command-palette row, extracting the shared `previewTarget`/`copyCmd` logic into the `onkeydown` handler analogous to each element's existing `onclick`.

- [ ] **6. Run the suite, browser-verify the CSS/a11y items, commit**

```bash
bash test/all.sh
git add crates/workbench-mesh/assets/command-center/host.js crates/workbench-mesh/assets/command-center/bench.js crates/workbench-mesh/assets/command-center/ops.js crates/workbench-mesh/assets/command-center/style-surfaces.css crates/workbench-mesh/assets/command-center/docs.js crates/workbench-mesh/src/client.rs
git commit -m "fix(mesh): devices empty-state, form field ids, Ops centering, room name guard, Docs keyboard access"
```

---

## Final Steps (after all 13 tasks)

- [ ] Dispatch the final whole-branch code reviewer (superpowers:requesting-code-review's code-reviewer.md) against the full diff from `main` (`git merge-base main HEAD`) to `HEAD`, using `scripts/review-package` from the subagent-driven-development skill.
- [ ] Address any Critical/Important findings from that review.
- [ ] Run `bash test/all.sh` and `cargo test` (from `crates/workbench-mesh/`) one final time — both must be fully green.
- [ ] Use superpowers:finishing-a-development-branch to decide merge/PR/keep/discard.
