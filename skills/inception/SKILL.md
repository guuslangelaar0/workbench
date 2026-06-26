---
name: inception
description: Use at the genesis of a greenfield project, or when running /workbench:inception — a scope-controlled product brainstorm that turns an idea into a small v1 spec plus a seeded backlog, and REFUSES to proceed until you have named what is explicitly OUT of v1. The cure for ideator over-scoping.
---

# Inception — scope-controlled product genesis

The failure this prevents: "I want X, Y, and Z" → a thousand half-built features no one asked for. Inception turns an idea into a **small, shippable v1** with an explicit cut line, a spec, and a seeded backlog — so the next step is `/workbench:loop`, not analysis paralysis.

Read `way_of_working.inception_depth` from `.workbench/config.json` (default `recommended`) — it sets how deep to go. Start by invoking `superpowers:brainstorming` to explore intent (the `leaner` tier may shorten this to a quick frame); inception adds the scope gate and the genesis sequence on top. (Process skills first: brainstorm, then build.)

## The hard gate (non-negotiable)
**You may not produce the spec, create repos, or seed any task until the ideator has named what is explicitly OUT of v1.** Not implied — named. If they resist ("everything's important," "let's just build it all"), push back plainly: "v1 is what we ship in weeks, not what the product becomes. What are we deliberately NOT building yet?" Keep asking until you have a concrete OUT list. This gate is the entire point of inception — do not skip it, do not soften it, do not proceed past it.

## Sequence

1. **Frame (one sentence).** What is it, for whom, why now? If it can't be said in a sentence, it isn't scoped yet — keep narrowing.
2. **Scope cut — the gate.** Two explicit lists:
   - **v1 IN** — the smallest set of capabilities that makes the product *real* (aim for ≤ 3–5). Each is a user-facing outcome ("a user can share a folder"), not a component ("a sharing service").
   - **v1 OUT** — named things deliberately deferred. **Refuse to continue until this list exists and is concrete.**
   - Success criteria: the demoable moment that proves v1 works.
3. **Shape.** Topology (single repo or multi-repo) plus the repo names and stacks; a sketch of the data model; the single riskiest assumption (plan to validate it first).
4. **Design** (UI products only). Establish a direction with `frontend-design` (or `figma` when mapping/building a design system) — one or two reference screens and the brand/voice basics. Skip entirely for non-UI work (CLI, library, service).
5. **Delivery.** Where it lives and how it ships: GitHub org/repos (visibility per repo), the CI/CD approach, the deploy target, and prod URLs. Capture concrete choices; anything genuinely undecided becomes a `.claude/tasks/decisions/` file — never stall the wizard on it.
6. **Output + handoff.**
   - Write a **spec** at `docs/superpowers/specs/<date>-<name>.md` (if `superpowers:brainstorming` already wrote a `…-design.md` spec there, **extend that file in place** rather than creating a second one): the framing, the v1 IN/OUT cut, the architecture and one key user flow as **Mermaid** diagrams (the docs rule — no ASCII art), the data model, the delivery plan, and the open decisions.
   - Record `project.repos`, `project.topology`, and `project.prod` into `.workbench/config.json` (if the project isn't initialized yet, run `/workbench:setup` first — inception is product-genesis; setup captures the way-of-working tiers).
   - **Seed the backlog**: turn each v1 IN capability into a `/workbench:task "<title>"` (give it a `**Track:**` and a rough `**Estimate:**`) so `/workbench:loop` has real work waiting. Never seed OUT-of-scope items as tasks.
   - Hand off: point the user at `superpowers:writing-plans` for the first subsystem, then `/workbench:loop`.

## Depth tiers (`inception_depth`)
- **leaner** — quick spec: frame + the IN/OUT gate + repos → write the spec and seed the backlog. Skip the deep brainstorm and the design exploration.
- **recommended** — the full sequence above: brainstorming → scope gate → shape → design → delivery → spec + backlog.
- **better** — additionally stress-test the scope with `grill-me` (interrogate it until it holds), run a multi-approach judge panel (generate 2–3 distinct product directions, score them, build the spec from the winner while grafting the best of the runners-up), and produce real visuals with `figma`/`frontend-design`.

## Principles
- Small and shipped beats big and stalled. Every capability you cut from v1 is a feature you didn't half-build.
- Decisions get made or queued — never silently deferred. A vague spec is how scope creep re-enters through the back door.
- The output is a runway, not a document: a spec a human can approve plus a backlog the loop can start on the same day.
