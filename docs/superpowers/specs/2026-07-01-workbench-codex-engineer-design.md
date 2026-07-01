# Workbench Codex Engineer Design

## Intent

Workbench should support a native Codex engineer lane through the OpenAI Codex
Claude Code plugin. The user-facing request is:

```text
Dispatch this task to Codex.
```

or:

```text
Use Codex as the engineer for task 0042.
```

Claude should map that to a Workbench command, not to a hand-written prompt or
the older disk-only bridge. The command should invoke the OpenAI Codex plugin's
`codex:codex-rescue` subagent path, which is the native plugin connection that
routes work into the Codex companion runtime.

## Current State

Workbench already has a Codex bridge, but it is mostly documentary:

- `skills/codex-bridge/SKILL.md` tells Claude to use `codex:rescue`.
- `skills/orchestration/SKILL.md` mentions `codex:rescue` for stuck work.
- `templates/codex/CODEX_COORDINATION.md.tmpl` gives Codex and Claude a shared
  disk protocol when the `codex` dial is enabled.
- `templates/codex/codex-teamlead-prompt.md.tmpl` can bootstrap a Codex
  teamlead prompt.
- `test/codex.test.sh` only verifies those templates and references.

The OpenAI Codex plugin exposes the native path Workbench should use:

- `/codex:rescue` is a Claude Code command.
- It invokes `Agent` with `subagent_type: "codex:codex-rescue"`.
- The `codex:codex-rescue` subagent forwards the task to
  `scripts/codex-companion.mjs task`.
- `/codex:setup`, `/codex:status`, `/codex:result`, and `/codex:cancel` handle
  setup and lifecycle around those Codex tasks.

The missing Workbench slice is a first-class command that makes Codex a real
Workbench engineer lane: claim a task, move it through the Workbench lifecycle,
send a task-shaped prompt to the Codex plugin, and record the handoff.

## Approaches Considered

### Recommended: Workbench Command Wrapping `codex:codex-rescue`

Add `/workbench:codex-engineer <task-id> [options]`, implemented as a Claude
Code command that uses the `Agent` tool with `subagent_type:
"codex:codex-rescue"`. The command reads the task file, claims it through the
existing coordination model, moves it to `in-development`, builds a structured
Codex prompt, and forwards runtime flags such as `--background`, `--wait`,
`--model`, and `--effort`.

This keeps Workbench on the supported OpenAI Codex plugin surface. It also keeps
the lead in charge: Codex implements, but Workbench still owns verification,
review, and lifecycle advancement.

### Alternative: Directly Call `codex-companion.mjs`

Workbench could shell out to the Codex plugin's companion script directly. That
would be faster to script, but it couples Workbench to another plugin's private
file layout and bypasses the command/subagent contract the Codex plugin already
documents.

Reject this for the first implementation.

### Alternative: Keep Disk-Only Codex Bridge

Workbench could keep generating `CODEX_COORDINATION.md` and ask humans to paste
prompts into Codex. That works as a fallback, but it is not the native
delegation experience the user wants and it does not let Claude automatically
launch a Codex engineer lane.

Keep it as fallback documentation only.

## Product Behavior

### Command

Add:

```text
/workbench:codex-engineer <task-id> [--background|--wait] [--fresh|--resume] [--model <model|spark>] [--effort <none|minimal|low|medium|high|xhigh>] [lane/repo hint]
```

The command should:

1. Parse the task id and optional runtime flags.
2. Read the matching task file under `.claude/tasks/`.
3. Refuse if the task is missing or already claimed by another live lead.
4. Claim the task through `scripts/coord/wb-coord` when available.
5. Move the task to `in-development` with `scripts/task-move.sh`.
6. Append a `## Notes` entry that records the Codex handoff, UTC time, execution
   mode, and any model/effort flags.
7. Invoke `Agent` with `subagent_type: "codex:codex-rescue"`.
8. Forward a structured Workbench prompt to Codex.
9. Leave verification and task advancement to `/workbench:verify`.

If the user asks in natural language, the command descriptions and orchestration
skill should make Claude route intents such as "give this to Codex", "let Codex
engineer this", or "dispatch task 0042 to Codex" to `/workbench:codex-engineer`.

### Codex Prompt Shape

The forwarded prompt should include:

- Project root and current branch.
- Task id and task file path.
- Task title, track, repo hints, acceptance criteria, and declared
  verification.
- Workbench rules: implement only this task, keep commits scoped, do not add
  `Co-Authored-By`, update the task notes, run the declared verification, and
  report exactly what changed.
- The instruction that Workbench will verify after Codex returns; Codex should
  not mark the task verified itself.

The prompt should preserve Codex runtime flags:

- `--background` and `--wait` select Claude Code execution mode.
- `--fresh` and `--resume` map to the Codex plugin's resume behavior.
- `--model spark` maps through the Codex plugin to `gpt-5.3-codex-spark`.
- Other explicit models pass through unchanged.
- `--effort` passes through only when the user supplies it.

### Missing Codex Plugin

If the OpenAI Codex plugin is unavailable or the `codex:codex-rescue` subagent
cannot be invoked, Workbench should stop before moving the task when possible
and guide the user to install/enable the OpenAI Codex plugin and run:

```text
/codex:setup
```

If failure happens after a task was claimed or moved, the command should append a
task note explaining that Codex launch failed and leave the task in
`in-development` for the lead to re-dispatch or move back.

### Relationship To Existing `/workbench:dispatch`

`/workbench:dispatch` remains the default Claude engineer lane. `/workbench:codex-engineer`
is a specialized dispatch command for Codex. The orchestration loop may choose
it only when:

- `way_of_working.codex` is `rescue-only` and the task is stuck, needs an
  independent implementation pass, or the user explicitly asks for Codex.
- `way_of_working.codex` is `full-lane` and the lead decides Codex is the best
  engineer for the task.
- The user directly says to use Codex.

When `way_of_working.codex` is `off`, the command may still run if the user
explicitly asks for it, but it should explain that the project dial is off and
record the handoff as user-directed.

## Files To Change

Expected implementation files:

- `commands/codex-engineer.md` - new Workbench command that invokes
  `codex:codex-rescue`.
- `skills/codex-bridge/SKILL.md` - update from rescue-only guidance to native
  Workbench engineer-lane guidance.
- `skills/orchestration/SKILL.md` - teach the lead when to choose Codex as an
  engineer.
- `docs/commands.md` and `README.md` - document the command.
- `test/codex.test.sh` - structural tests for command existence, routing text,
  native subagent reference, setup fallback, and prompt requirements.
- `test/command.test.sh` and/or `scripts/validate-plugin.sh` fixtures if the
  command surface inventory needs updating.

Optional implementation files:

- `scripts/codex-engineer-note.sh` only if appending task notes becomes too
  complex for command markdown.
- `templates/codex/CODEX_COORDINATION.md.tmpl` if the shared protocol needs to
  describe the new command.

## Testing

The first implementation should be testable without launching real Codex:

1. `bash test/codex.test.sh`
   - command file exists
   - command frontmatter is valid enough for plugin validation
   - command mentions `subagent_type: "codex:codex-rescue"`
   - command tells users to run `/codex:setup` when Codex is unavailable
   - command preserves `--background`, `--wait`, `--model`, and `--effort`
   - command requires the lead to verify after Codex returns
2. `bash test/command.test.sh`
   - command inventory includes `/workbench:codex-engineer`
3. `bash scripts/validate-plugin.sh`
   - plugin remains publishable
4. `bash test/all.sh`
   - full offline suite stays green

A later live test can be added behind an opt-in environment variable once a
stable Codex test fixture exists. The offline suite must not require Codex
credentials or network access.

## Release Scope

This feature is future work after v0.6.0. It should land under `Unreleased`
until the next version is prepared.

The release note should say:

- Workbench can dispatch a task to a native Codex engineer lane through the
  OpenAI Codex plugin.
- The lead still owns lifecycle, review, and verification.
- The old disk bridge remains a fallback, not the primary path.

## Self-Review

- Placeholder scan: no TODO/TBD markers remain.
- Scope check: this is one focused command and guidance update, not a broader
  Codex runtime rewrite.
- Dependency check: the design uses the OpenAI Codex plugin's documented
  command/subagent surface and avoids direct dependency on private companion
  script paths.
- Testability check: the core implementation can be verified offline by
  structural command tests; live Codex execution remains optional.
