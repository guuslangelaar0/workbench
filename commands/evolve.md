---
description: Convene an evolution summit — a project-configurable persona panel that generates new ideas, retrospectively audits verified/shipped work, and synthesizes critic-approved survivors into backlog tasks
allowed-tools: ["Bash", "Read", "Glob", "Grep", "Task", "TodoWrite"]
argument-hint: "[status | init | --force] [--track <track>]"
---

You are the `/workbench:evolve` command. **Invoke the `evolution` skill and follow it exactly** — it defines the summit structure (parallel generator personas → one critic pass → synthesis), the dual mandate, and the guardrails. This command is the entry point; the deterministic plumbing is `scripts/evolve.sh`.

Fast natural-language mapping: "convene the panel", "run a summit", "what should we build next in <track>?", or "have the board look at the backlog" mean this command. An un-committed one-off idea from the human still goes to `/workbench:suggest add`, not here.

Read `$ARGUMENTS` and act:

## `init`

Scaffold the persona roster + ideas ledger (idempotent, never overwrites an existing roster). Without `--preset`, the tier follows the project's maturity level in `.workbench/config.json` — solo gets the 2-persona preset (one broad generator + critic), pair/crew/fleet get the 3-generator crew preset:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/evolve.sh" init --target "${CLAUDE_PROJECT_DIR}" [--preset solo|crew|admin-example]
```

Then **help the human tailor the roster to their domain** (wizard-style, like `/workbench:setup`): read the scaffolded `.workbench/evolution/personas.json`, present the suggested tier as a *starting point*, and offer to rewrite the generator personas into this project's actual 2–3 genuinely distinct areas of concern — the persona-splitting heuristic is in the `evolution` skill. For an internal admin/ops-surface project, show the `admin-example` preset (a worked 4-generator panel) as a reference. Keep exactly ONE critic — the constraint is enforced by `evolve.sh validate`. The roster schema is `templates/schemas/personas.schema.json` in the plugin.

## `status`

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/evolve.sh" check --target "${CLAUDE_PROJECT_DIR}"
bash "${CLAUDE_PLUGIN_ROOT}/scripts/evolve.sh" roster --target "${CLAUDE_PROJECT_DIR}"
```

Report: enabled/disabled, whether a summit is due (and why), the configured panel, and the tail of `.workbench/evolution/ideas-log.md` (the last summit's entries) so the human can skim what the panel has been thinking.

## Run a summit (default, no argument)

1. **Trigger check first:**

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/evolve.sh" check --target "${CLAUDE_PROJECT_DIR}" [--track <track>]
   ```

   - `disabled` → evolution is opt-in; offer `init` and stop.
   - `invalid` → show the roster problems and stop (fix the roster first).
   - `not-due` → report the counts and stop, **unless** the human passed `--force` or explicitly asked to convene now (an explicit human request always counts as a trigger).
   - `due <reason>` → proceed.

2. **Convene the summit** per the `evolution` skill: record the summit start (`evolve.sh record-summit`), gather grounding (task dirs, decisions, the ideas ledger, `evolve.sh retro-candidates`, graphify report when present), fan out ALL generator personas as parallel subagents in a single batch, then run the single critic pass over their combined output, then synthesize approved ideas into real backlog tasks (`task-new.sh`, grouped under an epic via `epic-new.sh` when the level has epics and a theme warrants it) and log **every** raised idea to the ledger with its disposition (`evolve.sh log`).

3. **Report** — summit date, ideas raised / approved / killed / merged / deferred, retrospective audits done (task IDs), and the new task IDs now in `backlog/`. Then return to whatever you were doing — after a summit the loop resumes normal dispatch immediately; there is no separate mode.

If the project is unconfigured, defer to `/workbench:setup` first.
