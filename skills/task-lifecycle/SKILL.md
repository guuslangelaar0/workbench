---
name: task-lifecycle
description: Use when creating, moving, or verifying tasks in .claude/tasks/ — the file format, ID allocation, the git-mv state transitions, and the in-review cap. The lead owns all lifecycle transitions.
---

# Task lifecycle

Tasks are markdown files under `.claude/tasks/`. **Status is the subdirectory the file lives in**; transitions are `git mv`; full history is in git. The format spec is `.claude/tasks/README.md` in the project.

## States
The baseline is `backlog → in-development → in-review → verified`, plus `decisions/` (needs the human; the lead never blocks on it). The exact set is **derived from the project's maturity level** — it is not stored in config. Solo drops `in-review`; deploy-gated levels (Crew, Fleet) add `staged` then `shipped` (`verified → staged → shipped` — locally-verified work parks in `staged/` for build-on-staging + smoke; only a prod deploy reaches `shipped/`), and Fleet additionally has `release-candidate`. Get the project's actual stage dirs from its level via `wb_level_lifecycle <level>` (in `scripts/levels.sh`), or just `ls .claude/tasks/`.

## Create a task
Use `/workbench:task "<title>"`, or directly:
`bash "${CLAUDE_PLUGIN_ROOT}/scripts/task-new.sh" --title "<t>" --target "${CLAUDE_PROJECT_DIR}" [--track T] [--repos "a,b"] [--estimate "~1 day"]`
It allocates the next ID from `_next-id`, renders the canonical template, and bumps the counter atomically. Never hand-edit `_next-id`.

## Epics (pair level and up)

When the `decomposition` dial is grouped (pair = light-epics, crew = epics, fleet = themes-epics), related tasks group under an **epic** — a file in `.claude/epics/NNNN-title.md` describing one user-facing outcome. `solo` (decomposition = tasks) is flat and has no epics dir.

- **Create:** `/workbench:epic "<title>"` → `scripts/epic-new.sh`. Epics draw from the **same** `.claude/tasks/_next-id` counter as tasks, so an epic ID and a task ID are never the same number.
- **Link:** a task joins an epic via `**Epic:** <epic-id>` in its header — set at creation with `/workbench:task "<t>" --epic <id>`, or added by hand.
- **Status:** an epic is `open` until you mark it `done` (edit the file when all its child tasks are verified/shipped). Progress (`done/total` child tasks) rolls up live in `/workbench:mc` and `/workbench:epic list` — it is derived by scanning task `**Epic:**` fields, not stored.

Epics are a grouping lens, not a lifecycle stage: child tasks still flow through the normal stages independently.

## Move a task (lead-only)
Use `/workbench:dispatch` and `/workbench:verify`, or directly:
`bash "${CLAUDE_PLUGIN_ROOT}/scripts/task-move.sh" <id> <to-state> --target "${CLAUDE_PROJECT_DIR}"`
It `git mv`s the file (or plain `mv` if untracked) and rewrites the `**Status:**` field. The lead does ALL transitions — the workspace `.git` is lead-only; engineers report, they do not move task files.

## Done means verified
A task is **not done** until it reaches `verified/` (or `shipped/` when deploy-gated) with evidence captured in its `## Verification evidence` section. "In review" means code exists and awaits LOCAL verification — say "code committed, awaiting verification," never "done." If verification fails, move it **back** to `in-development/`, not "almost there."

## The in-review cap
`lifecycle.in_review_cap` (default 10) bounds `in-review/`. When the count reaches `cap − 3`, **hard-drain**: stop taking new work and verify oldest-first (by ID) until the count is `cap − 6` or lower. An unbounded in-review queue is where "done" claims pile up and the directory stops reflecting reality — the cap forces verification to happen continuously.
