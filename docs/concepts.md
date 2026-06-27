# Concepts

Workbench is a handful of small, file-based mechanisms that compose into a way of working. None of them are magic; all of them live in your repo as plain files. This page explains the model behind each.

---

## Task lifecycle

Tasks are **markdown files** under `.claude/tasks/`. A task's status *is the subdirectory it lives in* — there is no database, no status field that can disagree with reality. Moving a task between statuses is a `git mv`, so the full history is in git.

```mermaid
flowchart LR
    backlog --> dev[in-development] --> review[in-review] --> verified
    review -.fails.-> dev
    verified --> staged --> shipped
    dev -.needs human.-> decisions
    style verified fill:#064e3b,color:#fff
    style shipped fill:#064e3b,color:#fff
    style decisions fill:#7c2d12,color:#fff
```

Two rules make this honest:

- **"Done" means `verified/` (or `shipped/`), with evidence.** Reaching `in-review/` only means code exists and awaits verification — the language for that is "code committed, awaiting verification," never "done." If verification fails, the task moves *back* to `in-development/`, not "almost there."
- **The in-review cap.** No more than `lifecycle.in_review_cap` (default 10) tasks may sit in `in-review/`. As the queue fills, the loop stops taking new work and drains it oldest-first. A review queue with no ceiling is exactly where "done" claims accumulate and the board stops reflecting reality.

Which stages exist depends on your [level](levels.md#lifecycle-stages-per-level): `solo` skips `in-review`; `crew` adds `staged` + `shipped`; `fleet` adds `release-candidate`. `decisions/` — the queue for things that need a human — is present at every level.

The CLI behind it: `scripts/task-new.sh` (allocates the next ID, renders the template) and `scripts/task-move.sh` (the `git mv` + status-field rewrite). The lead owns all transitions.

**Epics** group related tasks under one user-facing outcome once your `decomposition` dial is grouped (pair and up). An epic is a file in `.claude/epics/NNNN-title.md`; a task joins it via an `**Epic:**` field, and the epic's `done/total` progress rolls up live in `/workbench:mc`. Epics and tasks share one ID counter (no collisions). It's a grouping lens, not a lifecycle stage — child tasks still flow through the stages independently. `solo` stays flat (no epics). See [commands.md](commands.md#workbenchepic-title---theme-t--workbenchepic-list).

---

## The orchestration loop

The loop is a long-running teamlead cycle. The lead **coordinates**; it does not write code. Engineers implement; verifiers check.

```mermaid
flowchart TD
    pick["pick the highest-impact<br/>UNBLOCKED task"] --> dispatch["dispatch to an engineer<br/>(own lane)"]
    dispatch --> gate{"verify-gate:<br/>review · build · run<br/>the declared verification"}
    gate -->|pass| advance["advance the task<br/>+ checkpoint"]
    gate -->|fail| back["back to in-development<br/>with notes"]
    advance --> replenish["keep 2–3 tasks queued;<br/>generate more from the roadmap"]
    back --> pick
    replenish --> pick
```

Principles the loop never violates:

- **Verified or it didn't happen.** Nothing advances past the gate without evidence — a passing command, a screenshot, a real check.
- **Bugs auto-file; features only suggest.** A bug found mid-task becomes a task automatically. A new *feature or improvement* is surfaced as a suggestion for a human to approve — never silently built. This is universal across all levels.
- **Autonomy scales inversely with level.** At `solo` the loop just keeps going (`auto-continue`). At `fleet` every suggested direction routes through review (`suggest-review`). More coordination surface → more pausing to confirm. (`scripts/loop-policy.sh` resolves the mode from the level or a `dial_overrides`.)
- **Never stop silently.** Blocked work moves laterally to another lane; decisions for a human go to `decisions/` and the loop continues; it never spins on the same failure.

---

## Continuity

Coding agents forget. Workbench makes forgetting safe with three hooks and a handoff file.

| Hook | When | What it does |
|------|------|--------------|
| `SessionStart` | every new session | Re-grounds from disk: injects an *operating brief* (project, level, task counts, what's in flight) so the session starts from reality, not a blank slate. |
| `PreCompact` | before context is compacted | Writes a durable checkpoint + a `SESSION_STATE.md` breadcrumb so nothing is lost when context is squeezed. |
| `PostToolUse` | throttled, during work | A lightweight presence heartbeat for multi-session coordination. |

The contract: **the next session should be able to resume from `SESSION_STATE.md` alone.** `/workbench:checkpoint` writes one on demand; `/workbench:boot` runs the full "verify reality, reconcile, brief" protocol when you start fresh.

---

## Coordination

When more than one Claude session is open on the same repo, they are separate processes that can clobber each other. Workbench's `scripts/coord/` tooling gives them presence and locks.

- Sessions **register** themselves and **claim** tasks; a second session sees the claim and steers clear.
- A **pre-commit guard** warns (or, at `strict` enforcement, blocks) a bulk commit when another live session has changes in the same repo — the fix is to commit with an explicit pathspec or isolate in a **worktree**.
- `/workbench:teamlead <topic>` scopes a session to a single track and locks its tasks, so multiple leads can run in parallel without collision.

The `enforcement` axis (`remind` / `warn-default` / `strict`) controls how forcefully the guards act.

---

## Discipline: brainstorm → spec → plan

Workbench leans on the [superpowers](https://github.com/obra/superpowers) skills for the *thinking* part of building. Before significant work, the expectation is brainstorm → spec → plan, then execute task-by-task with a fresh implementer per task and a review pass. `/workbench:inception` applies this to greenfield genesis: it turns an idea into a v1 spec and a seeded backlog, and refuses to proceed until you name what's explicitly **out** of v1 — scope control as a first-class step.

---

## The context backbone (architecture)

The `architecture` dial sets how formally a project maps itself, scaling with level: `none` → `context` → `containers` → `components` (a [C4](https://c4model.com)-style progression). The design intent is a two-sided model — *authored intent* (what you meant to build) versus *extracted reality* (what the code actually is, via knowledge graphs) — with the **drift between them treated as a first-class signal**. Higher levels and the `graphify` axis turn more of this on. (The deeper implementation of the context backbone is on the roadmap; see [docs/design/](design/) for the design rationale.)

---

## See also

- **[levels.md](levels.md)** — the ladder and the struggle each level solves
- **[configuration.md](configuration.md)** — every config field
- **[commands.md](commands.md)** — the full command reference
