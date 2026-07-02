---
name: evolution
description: Use when running /workbench:evolve or when the loop's evolve.sh check says a summit is due — the project-configurable persona panel (N generators + exactly one critic) that generates new ideas, retrospectively audits verified/shipped work, and synthesizes critic-approved survivors into normal backlog tasks.
---

# Evolution — the persona-panel summit

A project on workbench can keep replenishing its own backlog with *good* work — not by asking the human "what next?" every time the queue thins, but by convening a small panel of persona-agents (the **summit**) that generates, prioritizes, and feeds real tasks into the existing lifecycle. This skill is the summit's structure. The deterministic plumbing (trigger, roster validation, ledger, retrospective rotation) is `scripts/evolve.sh`; nothing here invents a new scheduler, task format, or approval gate.

**Why a scheduled summit and not a live team:** a permanently-open multi-agent panel burns tokens when there is nothing to discuss and drifts from disk state. The panel convenes, does its work, produces artifacts, and stops — cheaper, auditable, and just as "constant" over any meaningful horizon.

## Opt-in — and the carved rule

Evolution is **off by default**. The universal loop rule is "features are suggested, never auto-built" — creating `.workbench/evolution/personas.json` (via `/workbench:evolve init`) is the human's *standing approval* for panel-sourced backlog replenishment, scoped by that file's `track` knob. The ideas ledger is the audit trail that keeps the standing approval honest: every idea, verdict, and synthesized task ID is recorded where the human can skim it at their own cadence. No roster file → `evolve.sh check` prints `disabled` and the loop skips summits entirely.

## The roster — `.workbench/evolution/personas.json`

Project-configurable; schema in `templates/schemas/personas.schema.json`. Each persona has a `name`, a `role` (`generator` | `critic`), and a `prompt` (its role description, used verbatim as the agent-panel prompt). Constraints `evolve.sh validate` enforces — the schema alone gates nothing, the script is the enforcement: every persona named, at least one generator, **exactly one critic**, unique names, non-empty prompts, and the cost caps (max 10 personas, prompts ≤ 2000 chars, `retro_slice` ≤ 20, integer knobs). One critic wearing several lenses (actually-done? security/abuse exposure? UX coherence?) is sharper than several overlapping skeptics with diluted feedback — keep it that way.

**Trust model:** persona prompts are trusted project configuration — the same trust level as any other checked-in config file (whoever can edit `personas.json` already has repo write access). They are not attacker-controlled input; no wrapping or sandboxing is applied or needed. The less-trusted channel is the panel's *output* (AI-generated ideas), which is why retrospective coverage uses a structural ledger marker that output text cannot forge (see Synthesize below).

**Presets follow the maturity ladder** (`templates/evolution/personas.*.json`; `evolve.sh init` picks by the project's level, `--preset` overrides):

- `solo` — 2 personas: one broad generator + the critic. A solo-level project rarely has enough genuinely distinct domains to justify splitting voices.
- `crew` — 3 generators + the critic (the pair/crew/fleet default). The scaffolded generators (product-visionary, user-advocate, operator) are *placeholders for domains* — rewrite them into whichever 2–3 areas of concern are actually this project's biggest.
- `admin-example` — a **worked example**, not a default: the full 4-generator panel (product-visionary, support-lead, storage-ops, billing-ops + critic) from the one real instance of this mechanism, a project evolving an internal admin/ops control surface. Copy it only if those really are your domains.

**When to add a persona** — domain-driven, never size-driven. Add a generator when the project has a genuinely separate area of concern that keeps getting shortchanged because no voice owns it: its ideas would use different grounding, different vocabulary, and a different definition of "excellent" than the existing generators'. If a candidate persona's proposals would substantially overlap an existing one's, splitting is artificial busywork — sharpen the existing prompt instead. And never add a second critic: widen the one critic's lenses.

Knobs in the same file: `cadence_hours` (default 24), `queue_low_water` (default 2), `retro_slice` (default 3), `track` (default all), optional `description`.

## Trigger — whichever comes first

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/evolve.sh" check --target "${CLAUDE_PROJECT_DIR}"
```

Due when the unblocked backlog (for the configured track, honoring `Blocked-by` via `deps.sh ready`) drops below `queue_low_water` — the "keep 2–3 tasks queued" threshold — **or** strictly more than `cadence_hours` have passed since the last summit (so the retrospective mandate isn't starved while the backlog happens to be full). The very first check after enabling returns `due no-summit-yet` before any backlog/cadence evaluation. An explicit human request to convene always counts as a trigger. The loop consults this check as part of its normal rotation (see `orchestration`, Loop engineering) — there is no separate scheduler.

Other `check` outcomes: `disabled` (no roster — skip) · `invalid` (exit 2 — the roster fails validation; surface the printed problems and skip this summit, it is a config problem to fix, **not** a command failure) · exit 75 (another session holds the evolution lock this instant — skip and retry next rotation).

## The summit

One invocation, four stages. Record the start **first** (`evolve.sh record-summit` — stamps `last-summit` and appends the `## Summit` heading to the ledger) so a crashed summit can't re-trigger in a tight loop. `record-summit` is also the **atomic claim** of a due summit: `check`/`record-summit`/`log` serialize under an advisory lock, and record-summit refuses (exit 75) when another session recorded a summit within the last ~10 minutes — two leads can both see "due", but only the first claim wins. If it refuses, **stop: that other session owns this summit** — return to the loop, do not `--force`.

1. **Ground.** Before generating anything, read: the task dirs (`mc.sh --no-prod --no-build` + a listing of `backlog/`, `in-development/`, `verified/`, `shipped/`, `decisions/`) so the panel never proposes what's already queued, done, or explicitly decided against; the current code reality (`graphify-out/GRAPH_REPORT.md` where available, else brief direct exploration); and the **ideas ledger** so a rejected or already-tried idea isn't re-proposed identically. Pull the retrospective slice: `evolve.sh retro-candidates` (oldest verified/shipped task IDs without an `[audit:#NNNN]` marker entry in the ledger — the ledger itself is the coverage record; no separate tracking file).

2. **Generate — the dual mandate.** Fan out **all generator personas in a single parallel batch** (Task tool, `subagent_type: general-purpose`, model per the `models` skill). Each generator is ONE schema-constrained call, not a conversation. Each receives: its persona `prompt`, the grounding digest (compact — not raw file dumps), the ledger tail, and the retro slice, and must return two sections:
   - `IDEAS:` a short list — one line per proposed capability/gap + a one-paragraph rationale each.
   - `RETRO:` for each assigned task ID — is this actually excellent, or just checkbox-done? Should it be *more* than it already is? Verdict + one paragraph. "Complete and verified" is not the bar; "should this be bigger" is.

3. **Critique.** One second-stage call to the **critic** persona with all generator outputs together. Per idea (new and retrospective alike), a verdict: `approve` / `merge into <existing idea or task #NNNN>` / `kill: <reason>` / `defer: <reason>`. The critic can approve-as-is, shrink, or combine — its prompt defines its lenses.

4. **Synthesize.** You (the lead) turn survivors into real work — synthesis does not distinguish whether a survivor came from generation or retrospection:
   - **Apply the honesty triggers FIRST — before any survivor leaves `backlog/`.** A synthesized idea gets exactly the same judgment as any other task: if it touches money, security, schema, a public API, or anything expensive to reverse, it goes to `decisions/` for the human, not to dispatch. Panel provenance earns an idea *no* shortcut past that gate — if anything, panel-generated work deserves a beat MORE suspicion, because no human has read it yet.
   - Each approved idea → a normal backlog task via `task-new.sh --title … --track <track> --verification …` — the **existing** canonical task format (Why, Acceptance criteria, Scenarios, Verification ladder, Notes); fill in the Why and acceptance criteria from the persona's rationale. No new file format, no new directory.
   - **Mark provenance in the task file itself:** append to the new task's Notes section a line like `Origin: auto-generated by evolution summit <YYYY-MM-DD> (generator: <persona>); critic-approved. Apply honesty-trigger review before dispatch.` — so any human or later agent reviewing the file pays proportionate attention to its machine origin.
   - When several tasks share a theme large enough to warrant it and the level's `decomposition` dial has epics (pair and up), create the epic via `epic-new.sh` and link tasks with `--epic <id>`.
   - **Every raised idea gets a ledger entry** — approved or not: `evolve.sh log --persona <name> --idea "<one line>" --disposition "<d>"` with disposition one of `queued as task #NNNN` · `merged into existing task #NNNN` · `rejected by critic: <reason>` · `deferred: <reason>`. For retrospective coverage, log with the `--audit-of` flag: `evolve.sh log --persona <name> --audit-of <NNNN> --idea "re-examined …" --disposition "<verdict>"` — `--audit-of` writes the structural `[audit:#NNNN]` marker that rotation tracking counts. Free text that merely *mentions* a task id (in any idea or disposition, including persona output) is deliberately **never** counted as coverage, so adversarial or accidental phrasing in AI-generated output can't skip a task's audit.

Then return to the loop immediately — no separate mode, no handoff.

## Guardrails — nothing new

- **No new approval gate — but the existing one is NOT optional.** An idea touching money, security, schema, public API, or anything expensive to reverse flows through the **existing honesty triggers** → `decisions/` (see `orchestration` Step 7), exactly as any other task. One consistent safety net, not a bespoke one for "AI-generated" ideas. The synthesizing lead applies that judgment **at synthesis time, before the task leaves `backlog/`** — and every synthesized task carries its `Origin: auto-generated by evolution summit …` note (Synthesize, above) so later reviewers know to look twice.
- **The verification ladder is unchanged.** A panel-argued task still earns `verified/`/`shipped/` only through its declared verification with evidence. Deploy gates stay exactly as gated as they are today.
- **Quality drift is a prompt-tuning problem.** If the panel produces repetitive or low-value output, fix the persona prompts in `personas.json` — do not add a human-in-the-loop approval step back in, and do not let the summit skip the ledger.

## Composes with

`orchestration` (the loop consults `evolve.sh check` and convenes summits as part of its rotation) · `task-lifecycle` (synthesized tasks are normal tasks) · `models` (panel model resolution) · `/workbench:suggest` (a single un-committed human idea; the summit is the panel-scale counterpart) · `/workbench:epic` (theme grouping at pair+).
