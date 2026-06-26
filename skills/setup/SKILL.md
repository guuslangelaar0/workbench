---
name: setup
description: Use when running /initlab:setup, when bare /initlab finds no .initlab/config.json, or when any /initlab command is invoked in an unconfigured project. Runs the guided per-axis configuration wizard, writes .initlab/config.json, and scaffolds the project.
---

# initlab setup wizard

Configure a project's way of working, **one axis at a time**, each as an `AskUserQuestion` card. The user's battle-tested choice is the **Recommended** option (listed first); also offer **Better** (more thorough / pricier) and **Leaner** (cheaper / faster) with a plain-language cost note. Never dump all questions at once — walk them, but you MAY offer at the very start: "accept all Recommended and tune later, or walk each axis?" (a convenience; default is walk).

## Flow

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

4. **Write `.initlab/config.json`** with all answers (use the schema at `${CLAUDE_PLUGIN_ROOT}/templates/schemas/config.schema.json`; set `initlab.version` from the plugin's `plugin.json`, `initialized_at` to now). Write it BEFORE scaffolding.

5. **Scaffold**: run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/init.sh" --name "<name>" --mission "<mission>" --launch "<launch>" --profile full --target "${CLAUDE_PROJECT_DIR}"`. init.sh is a **greenfield scaffold: it never overwrites a file that already exists** — your richer config and any existing CLAUDE.md/AGENTS.md/SOUL.md/coord scripts are preserved (it reports which), and it only writes the files that are missing, plus the manifest + git hook. To reconcile preserved files against the current templates, the user runs `/initlab:upgrade` — that is the only path that touches existing managed files.

6. **Next step**: greenfield → offer `/initlab:inception` (the product-genesis brainstorm). Existing → tell them `/initlab:boot` then `/initlab:loop`. Summarize what was configured (the chosen tiers) and what was scaffolded.

## Principles
- The wizard is the first defense against the "ideator" failure: it makes the cost/quality tradeoffs explicit and forces intentional choices rather than silent maximalism.
- Other users get a different (valid) experience from the same plugin — the Recommended column is one opinionated default, not the only path.
