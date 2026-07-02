# Workbench Front Door Hooks Onboarding Design

## Intent

Workbench should feel easy for a new user:

```text
/plugin marketplace add guuslangelaar0/workbench
/plugin install workbench@workbench
/workbench:workbench
```

After that first front-door run, future Claude sessions in the repo should feel
Workbench-native. The user should be able to chat normally and have Claude route
work through Workbench's project memory, lifecycle, lead purpose, parking, mesh,
and verification habits without remembering every slash command.

## Current State

Workbench already has the right core pieces:

- `/workbench:workbench` is the front door.
- In configured projects, `hooks/bin/ground-session.sh` injects a SessionStart
  operating brief.
- `hooks/bin/intent-router.sh`, `lead-purpose-nudge.sh`, and `mesh-context.sh`
  add UserPromptSubmit context for natural-language routing.
- The generated `CLAUDE.md` templates tell Claude to treat Workbench as the
  way of working.
- `/workbench:setup` and `/workbench:init` exist as direct entry points.

The gap is product clarity. New users see multiple onboarding commands, and the
benefit of hooks is implicit. In an unconfigured repo the hooks no-op because
there is no `.workbench/config.json`, so Workbench does not feel "always on"
until the user has deliberately initialized the project.

## Goals

1. Make `/workbench:workbench` the single command users need to remember.
2. During onboarding, clearly offer hook installation as the recommended path.
3. Preserve an explicit lower-benefit path for users who do not want hooks.
4. Make `/workbench:setup` and `/workbench:init` refer back to the front door
   instead of presenting separate mental models.
5. After onboarding with hooks enabled, every new Claude session in the repo or
   subfolder should receive Workbench grounding from disk.
6. Test the actual user-facing outcome, not only file presence.

## Non-Goals

- No silent mutation of arbitrary repos merely because the plugin is installed.
- No hidden hook installation without the user accepting onboarding.
- No removal of `/workbench:setup` or `/workbench:init`; existing users may rely
  on those commands.
- No new daemon or mesh behavior in this feature.

## Approaches Considered

### Recommended: Front Door With Recommended Hooks Option

`/workbench:workbench` remains the main entry point. If the project is not
configured, it runs the level-aware onboarding flow and includes a clear choice:

```text
Install Workbench hooks? Recommended.
```

The recommended option installs the Workbench managed Claude Code hooks and
explains the benefit in human terms: new sessions re-ground from disk, normal
chat routes into Workbench actions, lead purpose is kept visible, tangents can
be parked, mesh/team context is surfaced, and compaction checkpoints preserve
continuity.

The alternate option skips hooks and explains that slash commands still work,
but Claude will not automatically re-ground or route normal chat.

This gives users control while making the best path obvious.

### Alternative: Auto-Install Hooks Without Asking

Workbench could install hooks automatically during init. This would maximize the
default experience, but it is too surprising for an onboarding command that
modifies agent behavior across future sessions.

Reject this.

### Alternative: Keep Hooks As Advanced Documentation

Workbench could leave hook installation as an advanced/manual step. That
preserves maximum caution, but it weakens the core promise: the user wants to
start chatting and have Workbench guide Claude by default after onboarding.

Reject this.

## Product Behavior

### `/workbench:workbench`

When `.workbench/config.json` is missing:

1. Explain that this repo is not configured yet.
2. Assess existing repo signals and recommend a Workbench maturity level.
3. Ask for the target level when confidence is low or the choice changes
   behavior materially.
4. Ask whether to install Workbench hooks, with "yes, recommended" as the
   default recommendation.
5. Scaffold the project through the existing init/setup implementation.
6. If hooks were accepted, install or update the managed Workbench hook config.
7. Show what is now active and what the user can do next.

When `.workbench/config.json` exists:

1. Show current status through `/workbench:mc` or the fallback task summary.
2. Report whether Workbench hooks appear installed and current.
3. If hooks are missing or stale, recommend installing/updating them.
4. Offer the natural next actions: continue the lead purpose, pick from backlog,
   run the loop, inspect suggestions, or reconfigure.

### `/workbench:setup`

`/workbench:setup` should remain callable, but its opening copy should say it is
the setup-focused entry point behind `/workbench:workbench`:

```text
This command is part of the /workbench:workbench onboarding flow. If you are not
sure what you need, run /workbench:workbench.
```

If called directly in an unconfigured repo, it may continue with setup. If
called directly in a configured repo, it should treat the run as reconfiguration
and include the same hook status/recommendation logic.

### `/workbench:init`

`/workbench:init` should be documented as the expert/scaffold command:

```text
/workbench:init is the low-level scaffolding command. Most users should start
with /workbench:workbench so Workbench can assess the repo and guide setup.
```

It should not become a competing onboarding path. Direct use remains supported
for power users and tests.

### Natural Chat After Onboarding

With hooks installed, new sessions should include enough context for Claude to
behave as a Workbench lead without requiring a slash command:

- SessionStart brief says Workbench is active.
- Lead purpose is visible when set.
- Latest open purpose is suggested when the new session has no purpose.
- Current task counts and suggestions are visible.
- Other live sessions and mesh context are visible when available.
- User prompts such as "what should we do next?", "start this task", "park that",
  "ask the other lead", or "this is a decision fork" get routed to the right
  Workbench command or protocol.

Workbench should still avoid creating files or tasks in a totally unconfigured
repo until the user accepts onboarding.

## Architecture

### Components

- `commands/workbench.md`: owns the front-door wording and the top-level state
  machine.
- `commands/setup.md`: becomes explicitly front-door-backed reconfiguration.
- `commands/init.md`: becomes explicitly low-level scaffolding.
- `skills/setup/SKILL.md`: owns the onboarding flow, including the hook choice.
- `scripts/init.sh`: continues to scaffold project files and should accept a
  hook mode or call a dedicated hook installer.
- Hook installer script: installs or updates the Workbench managed hook block in
  the project's Claude Code hook config while preserving unrelated user hooks.
- Hook status checker: reports installed/current/missing/stale so onboarding,
  status, and tests share one definition.
- Tests: cover command copy, hook installation behavior, idempotency, direct
  setup/init routing, and live-ish hook outputs.

### Data Flow

Unconfigured repo:

```text
user -> /workbench:workbench
     -> setup skill assesses repo
     -> user accepts level and hook recommendation
     -> init scaffolds .workbench, .claude, templates
     -> hook installer writes managed hooks
     -> front door reports active Workbench state
```

Configured repo:

```text
new Claude session
  -> SessionStart hooks run
  -> ground-session reads .workbench/config.json and .claude state
  -> Claude receives operating brief
  -> user chats normally
  -> UserPromptSubmit hooks add routing hints when relevant
```

## Error Handling

- If hook installation fails, setup should still complete the project scaffold
  and print the exact reason hooks were not installed.
- If an existing hook config contains non-Workbench hooks, preserve them.
- If a Workbench managed hook block is stale, update only that block.
- If the hook config is malformed and cannot be safely edited, stop hook
  installation and tell the user to repair the file or rerun with hooks skipped.
- If hooks are skipped, record the choice in Workbench config so future status
  can say hooks are disabled by choice rather than missing.

## Testing

Required offline tests:

1. Front-door command text names `/workbench:workbench` as the primary entry.
2. `/workbench:setup` and `/workbench:init` mention their relationship to the
   front door.
3. Onboarding text includes the recommended hook option and the lower-benefit
   skip option.
4. Hook installer preserves unrelated hooks and updates only the Workbench
   managed block.
5. Hook installer is idempotent.
6. Hook status checker reports installed, missing, stale, and disabled-by-choice.
7. A configured project with hooks emits the SessionStart operating brief.
8. UserPromptSubmit routing still emits hints for natural Workbench intents.
9. Subfolder startup resolves to the configured project root through
   `CLAUDE_PROJECT_DIR`.
10. `bash test/all.sh`, `bash scripts/validate-plugin.sh`, and
    `git diff --check` pass before merging.

Live verification can extend the current release gate by creating a temporary
project, running `/workbench:workbench` through Claude when available, then
starting a fresh Claude prompt in a subfolder and checking that the output uses
Workbench status instead of generic project advice.

## Release Notes

This should land under `Unreleased` until the next version is prepared.

Suggested release note:

- Workbench onboarding now makes `/workbench:workbench` the single front door,
  recommends hook installation for the full always-on experience, and clarifies
  that `/workbench:setup` and `/workbench:init` are setup/scaffold entry points
  behind the front door.

## Self-Review

- Placeholder scan: no placeholder markers remain.
- Consistency check: the design keeps `/workbench:workbench` as the primary
  path while preserving direct setup/init compatibility.
- Scope check: this is one onboarding and hooks feature, not a mesh or daemon
  change.
- Ambiguity check: hook installation is recommended and user-approved, not
  silent; skipping hooks remains supported with documented lower benefit.
