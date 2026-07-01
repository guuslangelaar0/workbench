# Workbench Codex Engineer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `/workbench:codex-engineer`, a native Workbench dispatch command that hands a task to the OpenAI Codex plugin through `codex:codex-rescue`.

**Architecture:** Keep Workbench as the lead/lifecycle owner and Codex as an engineer lane. The new command mirrors `/workbench:dispatch` for task lookup, claim, lifecycle move, and lead purpose, then invokes the OpenAI Codex plugin's `codex:codex-rescue` subagent with a structured Workbench task prompt. Offline tests verify the contract structurally; the actual cross-plugin subagent invocation remains a gated live check because it requires a Claude Code runtime with the Codex plugin installed.

**Tech Stack:** Claude Code plugin markdown commands, shell tests, Workbench task lifecycle scripts, OpenAI Codex Claude Code plugin subagent surface.

## Global Constraints

- Use the OpenAI Codex plugin's documented native surface: `Agent` with `subagent_type: "codex:codex-rescue"`.
- Do not shell out directly to another plugin's `scripts/codex-companion.mjs`; that is private plugin layout.
- Do not require Codex credentials, network, or live Claude Code in `test/all.sh`.
- Keep `/workbench:dispatch` as the default Claude engineer lane.
- `/workbench:codex-engineer` may run when `way_of_working.codex` is `off` only when the user explicitly asks for Codex.
- Codex implements; Workbench/Claude still verifies, reviews, and advances lifecycle.
- Do not bump plugin version during feature implementation; use `CHANGELOG.md` `[Unreleased]` only.

---

## File Structure

- `commands/codex-engineer.md` - new Workbench slash command. It owns parsing instructions, lifecycle/claim instructions, prompt construction, and the `codex:codex-rescue` Agent invocation.
- `test/codex.test.sh` - structural tests for the new command and Codex bridge guidance.
- `test/command.test.sh` - generic command-surface inventory checks for `/workbench:codex-engineer`.
- `skills/codex-bridge/SKILL.md` - updates the Codex guidance from "bridge/rescue" to "native Workbench engineer lane plus fallback bridge".
- `skills/orchestration/SKILL.md` - teaches lead sessions when to dispatch to Codex.
- `docs/commands.md` - command reference entry.
- `README.md` - command table and Works With update for OpenAI Codex.
- `templates/codex/CODEX_COORDINATION.md.tmpl` - generated project guidance that names `/workbench:codex-engineer`.
- `CHANGELOG.md` - `[Unreleased]` entry.

---

### Task 1: Specify the Codex Engineer Command Contract

**Files:**
- Modify: `test/codex.test.sh`
- Modify: `test/command.test.sh`

**Interfaces:**
- Consumes: existing `chk` shell helper in both test files.
- Produces: failing assertions that define the new command contract before implementation.

- [ ] **Step 1: Extend `test/codex.test.sh` with command-contract checks**

Insert these checks after the existing `skill refs codex:rescue` assertion:

```bash
chk "codex engineer command exists" "[ -f '$HERE/commands/codex-engineer.md' ]"
chk "codex engineer command uses native subagent" "grep -q 'subagent_type: \"codex:codex-rescue\"' '$HERE/commands/codex-engineer.md'"
chk "codex engineer command avoids direct companion shellout" "! grep -q 'codex-companion.mjs' '$HERE/commands/codex-engineer.md'"
chk "codex engineer command preserves runtime flags" "grep -q -- '--background' '$HERE/commands/codex-engineer.md' && grep -q -- '--wait' '$HERE/commands/codex-engineer.md' && grep -q -- '--model' '$HERE/commands/codex-engineer.md' && grep -q -- '--effort' '$HERE/commands/codex-engineer.md'"
chk "codex engineer command has setup fallback" "grep -q '/codex:setup' '$HERE/commands/codex-engineer.md'"
chk "codex engineer keeps workbench verification owner" "grep -q '/workbench:verify' '$HERE/commands/codex-engineer.md' && grep -qi 'do not mark the task verified' '$HERE/commands/codex-engineer.md'"
chk "codex bridge skill names native engineer command" "grep -q '/workbench:codex-engineer' '$HERE/skills/codex-bridge/SKILL.md'"
chk "codex coordination template names native engineer command" "grep -q '/workbench:codex-engineer' '$HERE/templates/codex/CODEX_COORDINATION.md.tmpl'"
```

- [ ] **Step 2: Extend `test/command.test.sh` with generic command checks**

Insert these checks after the mesh command assertions:

```bash
chk "codex-engineer command exists" "[ -f '$HERE/commands/codex-engineer.md' ]"
chk "codex-engineer command has frontmatter" "head -1 '$HERE/commands/codex-engineer.md' | grep -q '^---'"
chk "codex-engineer command uses Agent" "grep -q 'Agent' '$HERE/commands/codex-engineer.md'"
chk "codex-engineer command routes Codex natural intent" "grep -qi 'dispatch.*Codex\\|Codex.*engineer\\|give.*Codex' '$HERE/commands/codex-engineer.md'"
```

- [ ] **Step 3: Run the failing tests**

Run:

```bash
bash test/codex.test.sh
bash test/command.test.sh
```

Expected:

```text
FAIL: codex engineer command exists
FAIL: codex-engineer command exists
```

The exact number of failures can be higher because the command file does not exist yet.

- [ ] **Step 4: Commit the failing tests**

```bash
git add test/codex.test.sh test/command.test.sh
git commit -m "test: specify codex engineer command"
```

---

### Task 2: Add `/workbench:codex-engineer`

**Files:**
- Create: `commands/codex-engineer.md`

**Interfaces:**
- Consumes: Workbench task files under `.claude/tasks/`, optional `scripts/coord/wb-coord`, `scripts/task-move.sh`, `scripts/lead.sh`, and Claude Code's `Agent` tool.
- Produces: `/workbench:codex-engineer <id> ...` command that delegates to `subagent_type: "codex:codex-rescue"`.

- [ ] **Step 1: Create the command file**

Create `commands/codex-engineer.md` with this content:

```markdown
---
description: Dispatch a task to a native Codex engineer lane through the OpenAI Codex plugin
allowed-tools: ["Bash", "Read", "Agent", "TodoWrite"]
argument-hint: "<id> [--background|--wait] [--fresh|--resume] [--model <model|spark>] [--effort <none|minimal|low|medium|high|xhigh>] [lane/repo]"
---

Dispatch a task to Codex through the native OpenAI Codex plugin. Use this when the user says "dispatch this to Codex", "use Codex as the engineer", "give task 0042 to Codex", or asks for an independent Codex implementation lane.

You are still the Workbench lead. Codex is the engineer. You own task lifecycle, review, and verification after Codex returns.

1. Parse `$ARGUMENTS`:
   - first non-flag token is the 4-digit task id
   - preserve `--background`, `--wait`, `--fresh`, `--resume`, `--model <value>`, and `--effort <value>` for the Codex request
   - treat remaining text as a lane/repo hint
   - if no task id is present, ask for the task id

2. Read the task file under `${CLAUDE_PROJECT_DIR}/.claude/tasks/` for that id. Capture:
   - task file path
   - title
   - `**Track:**`
   - `**Repo(s):**`
   - `**Verification:**`
   - `## Acceptance criteria`
   - `## Scenarios`
   - `## Verification ladder`

3. If the OpenAI Codex plugin or `codex:codex-rescue` subagent is unavailable when invoking `Agent`, stop and tell the user to run `/codex:setup`. Do not call another plugin's `codex-companion.mjs` script directly from Workbench.

4. Check `way_of_working.codex` in `.workbench/config.json` when present:
   - `off`: continue only if the user explicitly asked for Codex; say the handoff is user-directed
   - `rescue-only`: use Codex for stuck work, second implementation passes, or explicit user requests
   - `full-lane`: Codex is an available engineer lane

5. Claim the task before moving it, when coordination is available:
   - `bash "${CLAUDE_PROJECT_DIR}/scripts/coord/wb-coord" claims task:<id>`
   - if another live session owns it, STOP and report the owner
   - otherwise `bash "${CLAUDE_PROJECT_DIR}/scripts/coord/wb-coord" claim task:<id>`
   - skip this silently when `scripts/coord/wb-coord` is absent

6. Move the task to in-development:
   `bash "${CLAUDE_PLUGIN_ROOT}/scripts/task-move.sh" <id> in-development --target "${CLAUDE_PROJECT_DIR}"`

7. Append a note to the task's `## Notes` section. Include UTC time, that Codex was assigned, the runtime mode (`--background` or `--wait`), and any `--model`/`--effort` flags. If there is no `## Notes` section, append one.

8. Set this lead session's purpose to the Codex-dispatched task:
   `bash "${CLAUDE_PLUGIN_ROOT}/scripts/lead.sh" set --target "${CLAUDE_PROJECT_DIR}" --session-id "<session-id>" --mode task --active-task "<id>" --track "<task Track field>" --purpose "<task title>"`

9. Invoke the `Agent` tool with `subagent_type: "codex:codex-rescue"`. Forward this prompt to Codex, preserving explicit runtime flags:

```text
You are Codex acting as a Workbench engineer lane.

Project root: <CLAUDE_PROJECT_DIR>
Current branch: <git branch --show-current output>
Task id: <id>
Task file: <task file path>
Lane/repo hint: <lane hint or "(none)">

Task title:
<title>

Task fields:
- Track: <track>
- Repo(s): <repos>
- Verification: <verification>

Acceptance criteria:
<acceptance criteria section>

Scenarios:
<scenarios section>

Verification ladder:
<verification ladder section>

Workbench rules:
- Implement only this task.
- Keep commits scoped to this task.
- Do not add Co-Authored-By.
- Update the task notes with what you changed and what you verified.
- Run the declared verification and report exact commands/results.
- Do not mark the task verified. Workbench will run /workbench:verify after you return.
```

10. If the `Agent` call fails after the task was claimed or moved, append a task note saying Codex launch failed and leave the task in `in-development` for the lead to re-dispatch or move back.

11. When Codex returns, report that the task is ready for Workbench verification. Do not claim it is done. Tell the user or lead to run `/workbench:verify <id>`.
```

- [ ] **Step 2: Run the targeted tests**

Run:

```bash
bash test/codex.test.sh
bash test/command.test.sh
```

Expected:

```text
PASS: codex
PASS: command
```

- [ ] **Step 3: Commit the command**

```bash
git add commands/codex-engineer.md test/codex.test.sh test/command.test.sh
git commit -m "feat: add codex engineer command"
```

---

### Task 3: Teach Workbench To Route Codex Engineer Work

**Files:**
- Modify: `skills/codex-bridge/SKILL.md`
- Modify: `skills/orchestration/SKILL.md`
- Modify: `templates/codex/CODEX_COORDINATION.md.tmpl`

**Interfaces:**
- Consumes: `/workbench:codex-engineer` command from Task 2.
- Produces: command routing guidance for leads and generated projects.

- [ ] **Step 1: Update `skills/codex-bridge/SKILL.md`**

Replace the "Handing work to Codex" bullet with:

```markdown
- **Native Workbench Codex engineer lane:** use `/workbench:codex-engineer <task-id>` when the user explicitly asks for Codex, when a task needs an independent Codex implementation pass, or when `way_of_working.codex` is `full-lane`. This command keeps Workbench as the lead/lifecycle owner and invokes the OpenAI Codex plugin through `subagent_type: "codex:codex-rescue"`.
- **Fallback rescue:** use `/codex:rescue` directly only when you are outside a Workbench task lifecycle or need a one-off Codex diagnosis. Use `/codex:setup` if the OpenAI Codex plugin is unavailable or unauthenticated.
```

- [ ] **Step 2: Update `skills/orchestration/SKILL.md`**

Find the sentence that currently says:

```markdown
When stuck or wanting a second opinion, hand the investigation to Codex (`codex:rescue`) if `way_of_working.codex` is not `off`, rather than looping.
```

Replace it with:

```markdown
When stuck or wanting a second implementation pass, hand the task to Codex with `/workbench:codex-engineer <task-id>` if the user explicitly asks for Codex or `way_of_working.codex` is `rescue-only`/`full-lane`. Use direct `/codex:rescue` only for one-off diagnosis outside the Workbench task lifecycle.
```

In the "Related skills" line near the bottom, replace `codex:rescue (when stuck)` with:

```markdown
`/workbench:codex-engineer` (native Codex engineer lane when stuck or user-directed)
```

- [ ] **Step 3: Update `templates/codex/CODEX_COORDINATION.md.tmpl`**

Add this paragraph after the "Codex should act as one of these" section:

```markdown
Claude can dispatch a task to Codex through `/workbench:codex-engineer <task-id>`. That command claims the task, moves it to `in-development`, invokes the OpenAI Codex plugin's native `codex:codex-rescue` subagent, and leaves verification with Workbench. Codex should update the task notes and report evidence, but it should not move the task to `verified`.
```

- [ ] **Step 4: Run routing tests**

Run:

```bash
bash test/codex.test.sh
bash test/orchestration.test.sh
```

Expected:

```text
PASS: codex
PASS: orchestration
```

- [ ] **Step 5: Commit routing guidance**

```bash
git add skills/codex-bridge/SKILL.md skills/orchestration/SKILL.md templates/codex/CODEX_COORDINATION.md.tmpl
git commit -m "docs: route codex engineer work"
```

---

### Task 4: Document The Command And Release Note

**Files:**
- Modify: `docs/commands.md`
- Modify: `README.md`
- Modify: `CHANGELOG.md`

**Interfaces:**
- Consumes: `/workbench:codex-engineer` command from Task 2.
- Produces: user-facing documentation and `[Unreleased]` release note.

- [ ] **Step 1: Update `docs/commands.md`**

Insert this section after `/workbench:dispatch`:

```markdown
### `/workbench:codex-engineer <id> [--background|--wait] [--model <model>] [--effort <level>]`
Move a task to `in-development/` and dispatch it to Codex through the OpenAI Codex plugin's native `codex:codex-rescue` subagent. Workbench still owns task claiming, lifecycle, review, and `/workbench:verify`; Codex acts as the engineer lane. If Codex is not set up, run `/codex:setup`.
```

- [ ] **Step 2: Update README command table**

Insert this row after `/workbench:dispatch <id>`:

```markdown
| `/workbench:codex-engineer <id>` | Dispatch a task to Codex through the OpenAI Codex plugin while Workbench keeps lifecycle and verification ownership |
```

- [ ] **Step 3: Update README Works With**

Add this bullet under `## Works with`:

```markdown
- **OpenAI Codex plugin** - optional native Codex engineer lane via `/workbench:codex-engineer`, backed by the Codex plugin's `codex:codex-rescue` subagent.
```

- [ ] **Step 4: Update `CHANGELOG.md`**

Under `## [Unreleased]`, add:

```markdown
### Added
- Native Codex engineer lane: `/workbench:codex-engineer` dispatches a Workbench task through the OpenAI Codex plugin's `codex:codex-rescue` subagent while keeping Workbench responsible for task lifecycle, review, and verification.
```

- [ ] **Step 5: Run documentation and package checks**

Run:

```bash
bash test/codex.test.sh
bash test/command.test.sh
bash scripts/validate-plugin.sh
```

Expected:

```text
PASS: codex
PASS: command
OK: workbench v0.6.0 is publishable
```

- [ ] **Step 6: Commit docs and changelog**

```bash
git add docs/commands.md README.md CHANGELOG.md
git commit -m "docs: document codex engineer command"
```

---

### Task 5: Final Verification And Live Assumption Gate

**Files:**
- No required source changes.
- Optional: append live-check evidence to `docs/superpowers/plans/2026-07-01-workbench-codex-engineer.md` only if the team wants the plan to carry execution notes.

**Interfaces:**
- Consumes: all previous tasks.
- Produces: verified feature branch ready for review or release preparation.

- [ ] **Step 1: Run full offline verification**

Run:

```bash
cargo fmt --check
cargo test --workspace
cargo build -p workbench-mesh
bash test/all.sh
bash scripts/validate-plugin.sh
bash scripts/bench.sh
git diff --check
```

Expected:

```text
ALL TESTS PASS
OK: workbench v0.6.0 is publishable
bench: OK
```

- [ ] **Step 2: Run the gated live Codex assumption check when credentials are available**

This check costs tokens and requires both Workbench and the OpenAI Codex plugin installed in Claude Code. Run it only when a live Claude/Codex environment is available:

```bash
WB_E2E=1 WB_E2E_MODEL="${WB_E2E_MODEL:-}" bash test/e2e/run.sh
```

Then manually test the new command in a scratch Workbench project with the OpenAI Codex plugin installed:

```text
/codex:setup
/workbench:task "codex smoke task"
/workbench:codex-engineer 0001 --wait --effort low
```

Expected:

```text
The command invokes `codex:codex-rescue` through Agent, Codex receives the Workbench-shaped task prompt, and the task remains owned by Workbench for `/workbench:verify 0001`.
```

If Claude Code reports that `codex:codex-rescue` is not available from a Workbench command, do not ship the command as-is. Replace Task 2 with a fallback design that prints a `/codex:rescue` command for the user to run manually, and update the spec before continuing.

- [ ] **Step 3: Record final status**

Run:

```bash
git status --short
git log --oneline --decorate -8
```

Expected:

```text
clean worktree
feature commits present on feature/codex-engineer-command
no version tag yet
```

- [ ] **Step 4: Push the feature branch**

```bash
git push origin feature/codex-engineer-command
```

- [ ] **Step 5: Report release readiness**

Report:

```text
Feature branch is verified and ready for review.
Offline verification passed.
Live Codex assumption check: passed / skipped with reason / failed with required fallback.
Release target remains v0.7.0 unless scope changes.
```

---

## Self-Review

- Spec coverage: Task 1 defines the command contract; Task 2 implements the native `codex:codex-rescue` command; Task 3 updates routing and generated Codex guidance; Task 4 updates user docs and `[Unreleased]`; Task 5 verifies offline and gates the live cross-plugin assumption.
- Marker scan: no unfinished-work markers remain. The only conditional branch is the explicit fallback if live Claude Code rejects cross-plugin subagent invocation.
- Type/name consistency: command name is `/workbench:codex-engineer`; command file is `commands/codex-engineer.md`; native Codex subagent string is `codex:codex-rescue`; setup fallback is `/codex:setup`.
- Scope check: the plan does not rewrite Codex runtime internals, add direct `codex-companion.mjs` shellouts, or require live Codex credentials in offline CI.
