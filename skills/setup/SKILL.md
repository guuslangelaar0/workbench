---
name: setup
description: Use when running /workbench:setup, when bare /workbench finds no .workbench/config.json, or when any /workbench command is invoked in an unconfigured project. Runs the level-aware adoption wizard: assesses existing repo signals, gives positive feedback, infers and recommends a maturity level, then runs the guided per-axis configuration wizard, writes .workbench/config.json, and scaffolds the project.
---

# workbench setup wizard

## Step 0: Assess the existing project (run first, before asking any questions)

Before prompting the user for anything, **read the project signals** to understand what's already in place:

- **Git history**: `git log --oneline -20` — how many commits, how long running, branching patterns
- **Branch model**: `git branch -a` — feature branches? main-only? tags?
- **Tags**: `git tag` — are there versioned releases?
- **Repo count**: is this a single repo or a multi-repo workspace?
- **Existing tasks/docs**: does `.claude/tasks/` exist? `CLAUDE.md`? `AGENTS.md`? `SOUL.md`?

Then **give positive feedback**: name what's already good. Example: "You have 87 commits with consistent message style, a feature-branch workflow, and two tagged releases — that's a solid foundation." Be specific, not generic. This is the first thing the user hears — make it feel like a colleague who's paying attention, not a form.

## Step 0a: Check Superpowers availability

Run `claude plugin list --json` when the CLI is available. If `superpowers@claude-plugins-official` is not installed/enabled, tell the user:

```text
Workbench works best with Superpowers for brainstorm -> spec -> plan, TDD, code review, verification-before-completion, and subagent-driven development.
Install it with:
/plugin install superpowers@claude-plugins-official
```

Map these user intents to Superpowers when available:
- "brainstorm/spec this properly" -> `superpowers:brainstorming`
- "write the implementation plan" -> `superpowers:writing-plans`
- "build this test-first" -> `superpowers:test-driven-development`
- "build with subagents" -> `superpowers:subagent-driven-development`
- "review before shipping" -> `superpowers:requesting-code-review`
- "prove it is done" -> `superpowers:verification-before-completion`

## Step 0b: Infer level and recommend

**Run the detector — don't eyeball it.** It maps the same git/repo signals to a level deterministically:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/detect-level.sh" "${CLAUDE_PROJECT_DIR}"
```

Its first line is `recommended=<level>`; the lines below are the signals it weighed (committers, release tags, non-trunk branches, repo count). It takes the *strongest* signal — e.g. a 2-committer repo with 5 repos under `repos/` recommends `crew`. For reference, the mapping it encodes:

| Level | Signals that suggest it |
|-------|------------------------|
| `solo` | Single committer, main-only or rare branches, no tags, no task system |
| `pair` | 2–3 committers or a feature-branch pattern, some tags, light task tracking |
| `crew` | 3–8 committers, tagged releases, epics/milestones, multi-repo |
| `fleet` | 8+ committers, release trains, release-candidate branches, federated repos |

State the recommendation plainly using its output: "Based on your git history — *<the signals it printed>* — this looks like a **<recommended>**-level project." Then ask: "Does **<recommended>** sound right, or would you like to adjust?" — the level override question. The chosen level becomes the `--level` argument to `init.sh`. (The detector is recommend-only; the human always decides.)

The per-axis dial questions below remain available as the **override mechanism** — after level selection, offer to walk the axes for fine-tuning, or accept all level defaults and scaffold immediately.

## Step 0c: Ask the Workbench hooks question

Ask:

```text
Install Workbench hooks? Recommended.
```

Options:

- **Yes, recommended** — new Claude sessions re-ground from disk, normal chat routes into Workbench actions, lead purpose stays visible, tangents can be parked, mesh/team context is surfaced, and compaction checkpoints preserve continuity.
- **No, skip hooks** — slash commands still work, but Claude will not automatically re-ground or route normal chat through Workbench in future sessions.

Record the answer as `--hooks enabled` or `--hooks disabled` when calling `init.sh`.

## Flow (continues after assessment)

1. **Project basics** (not tiered — ask directly): project name; one-line mission; launch target (optional); greenfield or existing project; repo topology (single repo or multi-repo workspace) + repo names/stacks if known; production URLs if any.
2. **Tiered axes** — ask each as an `AskUserQuestion` (Recommended first). The axis definitions:

| Axis (config key) | Leaner | **Recommended** | Better |
|---|---|---|---|
| `models` | Sonnet engineers · Haiku utility · Opus only lead+hardest | Teammates inherit session model · utility subagents Sonnet · never Haiku for reasoning | Opus for lead + every engineer + verifier |
| `verification` | Engineer self-verifies; lead spot-checks | Independent verifier agent per task + run the task's declared Verification | Verifier + adversarial skeptics (majority must confirm) |
| `review` | Lead eyeballs the diff | `superpowers:requesting-code-review` per significant task | `pr-review-toolkit` multi-agent + `/code-review ultra` |
| `parallelism` | Single engineer, sequential | 2–3 lanes + verifier | Large fleet, many concurrent lanes |
| `enforcement` | Remind only | Warn-default guardrails (block only the genuinely dangerous) | Strict blocking |
| `continuity` | Manual checkpoint | 30-min cadence + PreCompact + SessionStart re-ground | 15-min + Stop reminder + full boot every session |
| `graphify` | Off | Per-repo; update after changes; read before architecture Qs | + workspace graph + auto-update each change + query-first |
| `codex` | Off | Rescue-only (`codex:rescue` for stuck / second opinion) | Full parallel engineer lane |
| `remote` | Off | **Telegram** — official Channels plugin, two-way status + decisions | Telegram + Remote Control (Claude app) |
| `inception_depth` | Quick spec | brainstorming → spec → plan with scope control | + `grill-me` stress test + multi-approach judge panel + visuals |

Cost-note guidance: phrase Better as "more thorough / higher spend", Leaner as "cheaper / faster, a bit more lead babysitting", Recommended as "balanced; you control spend by what you launch". Map each answer to the config value: tiered axes that store tier names use `leaner`/`recommended`/`better`; `enforcement` stores `remind`/`warn-default`/`strict`; `graphify` stores `off`/`per-repo`/`full`; `codex` stores `off`/`rescue-only`/`full-lane`.

- **`remote` is a 4-way channel choice, not strict tiers** — present it as one AskUserQuestion with: **Off** (`off`); **Native** — drive from the Claude app, push to your phone, for users who don't use Telegram (`native`); **Telegram** (Recommended) — the official Channels plugin, two-way status + remote decision answering (`telegram`); **Both** — Telegram + Remote Control together (`both`). Telegram is the Recommended default.

3. **Remote setup help** — if `remote` is `telegram`/`both`, tell the user the install steps for the official plugin (`/plugin install telegram@claude-plugins-official` → `/telegram:configure <BotFather token>` → launch with `--channels` in a persistent terminal → pair + `/telegram:access policy allowlist`); keep the bot token in `~/.claude/channels/telegram/.env`, never in git.

4. **Write `.workbench/config.json`** with all answers (use the schema at `${CLAUDE_PLUGIN_ROOT}/templates/schemas/config.schema.json`; set `workbench.version` from the plugin's `plugin.json`, `initialized_at` to now). Write it BEFORE scaffolding.

5. **Scaffold**: run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/init.sh" --name "<name>" --mission "<mission>" --launch "<launch>" --level "<chosen-level>" --profile full --hooks "<enabled-or-disabled>" --target "${CLAUDE_PROJECT_DIR}"`. The `--level` flag uses the level chosen in Step 0b (solo/pair/crew/fleet). The `--hooks` flag uses the answer from Step 0c.

6. **Next step**: greenfield → offer `/workbench:inception` (the product-genesis brainstorm). Existing → tell them `/workbench:boot` then `/workbench:loop`. Summarize what was configured (the chosen tiers) and what was scaffolded. If hooks are enabled, tell the user the next Claude session in this repo should automatically receive a Workbench operating brief. If hooks are disabled, tell the user that `/workbench:*` commands still work and hooks can be enabled later from `/workbench:workbench`.

## Principles
- The wizard is the first defense against the "ideator" failure: it makes the cost/quality tradeoffs explicit and forces intentional choices rather than silent maximalism.
- Other users get a different (valid) experience from the same plugin — the Recommended column is one opinionated default, not the only path.
