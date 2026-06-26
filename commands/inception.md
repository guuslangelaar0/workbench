---
description: Scope-controlled product genesis — turn an idea into a v1 spec + seeded backlog (refuses to proceed without naming what's OUT)
allowed-tools: ["Bash", "Read", "Write", "Edit", "AskUserQuestion", "Glob", "Grep"]
argument-hint: "[one-line product idea]"
---

Run the workbench inception wizard for a (greenfield) project. **Invoke the `inception` skill and follow it** — especially its hard gate: do not produce a spec, repos, or tasks until the user has named what is explicitly OUT of v1.

1. Take any product idea from `$ARGUMENTS` as the starting frame (ask for a one-line idea if none was given).
2. Begin with `superpowers:brainstorming` to explore intent, then apply the inception scope gate (v1 IN / v1 OUT — refuse to proceed without the OUT list) and the genesis sequence (shape → design → delivery → output).
3. Read `way_of_working.inception_depth` from `.workbench/config.json` (default `recommended`) for how deep to go; if the project isn't initialized yet, suggest `/workbench:setup` for the way-of-working tiers.
4. End with: a spec under `docs/superpowers/specs/` (Mermaid for every diagram), `project.repos`/`topology`/`prod` recorded in config, the v1 backlog seeded via `/workbench:task`, and a pointer to `superpowers:writing-plans` then `/workbench:loop`.

Never seed OUT-of-scope items as tasks. Use Mermaid for all diagrams in the spec.
