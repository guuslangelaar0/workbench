# Command reference

All commands are namespaced `/workbench:*`. The bare `/workbench` is the front door — if you only remember one, remember that.

Every command defers to setup when the project is unconfigured, so running anything on a fresh project guides you into configuration first.

---

## Front door & setup

### `/workbench:workbench`
Context-aware entry point (the front door). On an **unconfigured** project it runs the setup wizard. On a **configured** one it prints current status (level, task counts, what's in flight) and the next sensible actions. Type `/workbench` to filter the command menu to the whole family — Claude Code namespaces every plugin command as `/<plugin>:<command>`, so there is no bare `/workbench`.

### `/workbench:setup`
The guided, per-axis setup wizard. Walks each configuration choice as a card with *leaner / recommended / better* options and a plain-language cost note, writes `.workbench/config.json`, then scaffolds. This is what `/workbench:workbench` calls on a fresh project.

### `/workbench:init`
Non-interactive scaffold. Renders templates + manifest into the project. Preserves an existing `.workbench/config.json` (the wizard owns it). Useful for re-scaffolding or scripted setup. Accepts `--name`, `--level`, `--profile minimal|full`, `--target <dir>`.

### `/workbench:uninstall`
Project-level uninstall. Reads `.workbench/manifest.json`, dry-runs by default, and removes only unchanged workbench-owned `managed` files plus recorded side-effect blocks such as `.gitignore` and pre-commit hook snippets. It preserves `merge`, `once`, pre-existing, edited, and data files unless you explicitly apply a more destructive mode. This is separate from `/plugin uninstall workbench@workbench`, which only removes the Claude plugin from Claude Code.

---

## The maturity ladder

### `/workbench:level [status | up | down | <name>]`
- **(no arg)** or **`status`** — print the current level and all seven resolved dials (marking any `dial_overrides`).
- **`up`** / **`down`** — move one step along `solo → pair → crew → fleet`. Shows the dial diff and the lifecycle directories it will add, then asks before applying.
- **`<name>`** — jump directly to `solo`, `pair`, `crew`, or `fleet`.

Graduation is recommend-only; it never changes your level without confirmation. See [levels.md](levels.md).

---

## The work loop

### `/workbench:loop`
Run the autonomous teamlead loop: pick the highest-impact unblocked task → dispatch to an engineer → verify-gate → advance or send back → replenish the queue → repeat. The lead coordinates; it does not write code. Bugs auto-file as tasks; new features are suggested, never auto-built. Autonomy scales with your level. See [concepts.md](concepts.md#the-orchestration-loop).

### `/workbench:task "<title>"`
Create a task. Allocates the next ID from `_next-id`, renders the canonical task format into `backlog/`. Optional fields: track, repos, estimate.

### `/workbench:lead [status | set "<purpose>" | adopt | clear]`
Manage this session's durable lead purpose. A lead purpose records what this session is for — one active task, one track, or an intentional backlog-scouting pass — under `.workbench/leads/`. `status` shows the current purpose and the latest open purpose if this session has none. `set` pins a new purpose. `adopt` copies the latest open purpose into this session after a resume or new tab. `clear` closes the purpose when the task/track is no longer owned.

### `/workbench:park "<title>" [--type bug|feature|follow-up]`
Park unrelated work as a real backlog task with origin metadata: session, active task, current purpose, and branch. Use it when a lead working one feature finds a different bug, feature idea, cleanup, or follow-up. If code already exists for the tangent, capture the relevant context or diff in the parked task; only revert code after explicit confirmation.

### `/workbench:epic "<title>" [--theme <t>]` / `/workbench:epic list`
Create or list **epics** — groups of related tasks under one user-facing outcome (`.claude/epics/NNNN-title.md`). Available at levels whose `decomposition` dial is grouped (pair = light-epics, crew = epics, fleet = themes-epics); `solo` uses flat tasks and has no epics. Epics draw from the shared `.claude/tasks/_next-id` counter, so epic and task IDs never collide. Link a task with `/workbench:task "<t>" --epic <id>`; the epic's `done/total` rollup shows in `/workbench:mc`. See [concepts.md](concepts.md#task-lifecycle).

### `/workbench:dispatch <id> [--worktree [name]|--shared] [--background|--wait] [lane]`
Move a task to `in-development/` and dispatch it to an engineer subagent in the given lane. Engineer/verifier agents use Claude Code native `isolation: worktree`; for multiple same-repo lanes, use `--worktree --background` to launch a native `claude --worktree <name> --bg --agent engineer` lane and monitor it with `claude agents`. `--shared` avoids a persistent/background worktree and uses the normal foreground Task-tool lane; that lane can still use Claude's temporary worktree isolation. When a lane needs current-branch state, commit/push that state or set Claude Code `worktree.baseRef` to `"head"` before launch.

### `/workbench:codex-engineer <id> [--background|--wait] [--fresh|--resume] [--model <model>] [--effort <level>]`
Move a task to `in-development/` and dispatch it to Codex through the OpenAI Codex plugin's native `codex:codex-rescue` subagent. Workbench still owns task claiming, lifecycle, review, and `/workbench:verify`; Codex acts as the engineer lane. If Codex is not set up, run `/codex:setup`.

### `/workbench:verify <id>`
Run a task's declared verification, review the diff, build, and gate it: on pass → `verified/` (or `staged/` if deploy-gated) with evidence captured; on fail → back to `in-development/`.

### `/workbench:mc`
Mission Control — a text dashboard of tasks by stage, the in-review cap, decisions, build status, and prod health. Flags: `--no-prod` (skip network checks), `--no-build` (skip cargo/tsc).

---

## Multi-session & greenfield

### `/workbench:teamlead <topic>`
Designate this session a topic lead. Scopes task-picking to one `**Track:**`, records the lead purpose, and locks its tasks via the coordination tooling so multiple leads can run in parallel without colliding.

### `/workbench:inception`
Scope-controlled product genesis for a greenfield project: turns an idea into a v1 spec and a seeded backlog, refusing to proceed until you name what's explicitly **out** of v1.

### `/workbench:architecture [view | drift]`
View or reconcile the **context backbone** in `.claude/architecture/` — C4-style authored-intent docs (context → containers → components) scaled by the `architecture` dial. `view` summarizes the intended shape; `drift` compares it against graphify's extracted reality and surfaces divergences (dependencies in code but not docs, god-nodes, intent with no code) to reconcile. `none` at solo; enabled by `/workbench:level up`. See [concepts.md](concepts.md#the-context-backbone-architecture).

---

## Workbench Mesh

### `/workbench:mesh start --local`
Start the Rust-backed command center on this machine only. Durable same-user credential material lives outside git under `$WORKBENCH_HOME` (`~/.workbench` by default) with OS-protected permissions. The wrapper launches `bin/workbench-mesh` through `scripts/mesh.sh` and writes ignored project runtime metadata to `.workbench/mesh/server.json` for host/port discovery; that metadata may include an ephemeral local daemon access token, but not the durable credential or root key, and `open` does not print tokenized daemon URLs. When the port is auto-assigned, use `/workbench:mesh open` to print the cached command-center URL.

On first `/workbench:mesh` use, Workbench resolves the Rust binary in this order: bundled binary, checksum-verified cached binary under `${CLAUDE_PLUGIN_DATA}`, local development build, then a GitHub release download verified against `checksums.txt`. If no verified asset exists for your platform, it prints the exact `cargo build --release -p workbench-mesh` fallback instead of running an unsigned binary.

### `/workbench:mesh start --lan`
Start the command center on the local network for another trusted machine on the same LAN. The output shows the hostname form, the `.local` mDNS form, the raw LAN IP, and the port, then keeps public internet exposure unavailable in this version. Use `/workbench:mesh invite --role worker --ttl-seconds 900` to create a scoped invite token.

### `/workbench:mesh invite [--role ROLE] [--ttl-seconds N] [--max-uses N]`
Create a LAN invite token. Tokens are the auth boundary for another machine joining the mesh; local same-user access uses durable credentials stored under `$WORKBENCH_HOME` / `~/.workbench`, not project-local `.workbench/mesh/server.json`. `ROLE` defaults to `worker`.

### `/workbench:mesh connect [URL] TOKEN [DEVICE]`
Accept an invite token for this device. Without `URL`, the token is redeemed against the local project runtime. With `http://HOST:PORT`, the token is redeemed against a trusted LAN mesh host, and the joining device stores its credential under `$WORKBENCH_HOME/mesh/`. The token is a command argument, not a URL parameter.

### `/workbench:mesh devices` / `/workbench:mesh revoke-device DEVICE`
List connected LAN devices or revoke a device credential. Revocation happens on the daemon-side hashed device registry, so an already-issued remote bearer token stops working immediately.

### `/workbench:mesh status | who | jobs | open`
Inspect the mesh runtime. `status` and `who` show registered actors and rooms, `jobs` lists recent job/task events, and `open` prints the cached non-tokenized command-center URL from ignored discovery metadata in `.workbench/mesh/server.json`.

### `/workbench:mesh room NAME`
Create or join a structured room. Lead channels conventionally use names like `lead:checkout` so multiple leads can coordinate without collapsing into one global chat.

### `/workbench:mesh message TARGET TEXT...` / `/workbench:mesh ask TARGET QUESTION...`
Send a message or question to an actor or room. Natural phrasing routes here: "talk to my MacBook Claude session" means inspect/start/invite as needed, "open a lead channel" means create a lead room, and "ask worker status" means address the worker actor with an ask/status request.

### `/workbench:mesh handoff TASK_ID TARGET`
Record a task handoff to another actor, preserving who handed off what and where the next owner should respond.

### `/workbench:mesh availability STATE [--reason TEXT]` / `/workbench:mesh doing TEXT...`
Publish this actor's availability and current work. The statusline hook reads the cached mesh snapshot so presence can show up cheaply without hitting the live API on every prompt.

### `/workbench:mesh watch ACTOR`
Follow updates for a lead, subagent, worker, or job actor. The actor hierarchy is: **leads** coordinate rooms and task ownership, **subagents** do delegated role work, **workers** represent joined devices/sessions, and **jobs** represent handoffs or task executions.

---

## Continuity & maintenance

### `/workbench:boot`
Boot protocol for a fresh session: verify reality from disk, reconcile against `SESSION_STATE.md`, then brief — and wait for "go" before starting the loop.

### `/workbench:checkpoint`
Write a `SESSION_STATE.md` checkpoint now, so the next session can resume from it alone.

### `/workbench:upgrade`
Reconcile this project's scaffolded files to the current plugin version: regenerate untouched mechanism files, semantically merge user-edited docs, never clobber your edits silently.

### `/workbench:doctor`
Health-check: validate the config against the schema, report drift between the manifest and the files on disk, flag stale state and an over-cap in-review queue.

### `/workbench:self-test`
Plugin-source self-test for workbench contributors. Validates plugin JSON, marketplace JSON, shell syntax, publishability via `scripts/validate-plugin.sh`, and the full offline shell suite unless called with `--skip-suite`.

---

## Remote

### `/workbench:remote`
Operate the project from your phone over the official Telegram Channels plugin: status + decisions, an outbound `Notification`→Telegram nudge, and a `PreToolUse` guard that hard-blocks catastrophic commands (`rm -rf`, force-push) on remote-driven sessions. Active only when `way_of_working.remote != off`.

---

## Under the hood

The commands are thin markdown wrappers over the scripts in `scripts/`, which you can also run directly:

| Script | Purpose |
|--------|---------|
| `init.sh` | Scaffold a project (level-aware) |
| `uninstall.sh` | Project-level uninstall using the manifest ledger |
| `task-new.sh` | Create a task file + allocate ID |
| `task-move.sh` | Move a task between stages (`git mv` + status rewrite) |
| `mc.sh` | Render the Mission Control dashboard |
| `levels.sh` | The maturity-ladder source of truth (presets, dial resolution) |
| `loop-policy.sh` | Resolve the loop autonomy mode for the current level |
| `detect-level.sh` | Recommend a *starting* level for a project being adopted, from git signals (recommend-only) |
| `graduate.sh` | Detect when a *configured* project has outgrown its level (recommend-only) |
| `drift.sh` | Classify scaffolded files as ok / edited / missing |
| `upgrade.sh` | Deterministic upgrade classifier (`ok`, `edited`, `missing`, `preexisting`, `template-changed`) |
| `doctor.sh` | Deterministic health report for scaffolded projects |
| `self-test.sh` | Contributor self-test for plugin source validation |
| `arch-drift.sh` | Align authored C4 docs against graphify-extracted reality (architecture drift) |
| `mesh.sh` | Wrapper for the Rust `bin/workbench-mesh` runtime and natural `/workbench:mesh` operations |
