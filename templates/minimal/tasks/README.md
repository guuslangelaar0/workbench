# `.claude/tasks/` — local file-based task tracking

Status is which subdirectory a task file is in. Transitions are `git mv`. Full history is in git.

## Layout

```
.claude/tasks/
├── README.md
├── _next-id             # 4-digit ID counter — read, increment, write back
├── backlog/             # Not started
├── in-development/      # Active work, an engineer is on it
├── in-review/           # Code committed, awaiting LOCAL verification (cap: 10)
├── verified/            # Done — locally verified, evidence captured
└── decisions/           # Needs the human's input; the lead does not block on these
```

## Task file naming

`NNNN-kebab-case-slug.md` where `NNNN` is a 4-digit zero-padded ID from `_next-id`.

## Task file format

```markdown
# 0042 — Implement folder sharing

**Status:** in-development
**Track:** sharing
**Repo(s):** web, server
**Estimate:** ~1 day
**Created:** 2026-06-20
**Verification:** <how this is verified — the command, the screenshot, the evidence>

## Why
<one paragraph: the user-facing reason this exists>

## Acceptance criteria
- [ ] ...

## Notes
<timestamped progress + the owner line when claimed>

## Verification evidence
(populated when moved to verified/)
```

Required fields: ID in title, `**Status:**`, `**Repo(s):**`, `**Verification:**`, `## Why`.
Optional fields: `**Track:**` (topic-lead scoping), `**Estimate:**` (surfaced in `/workbench:mc`), `**Created:**`. Create tasks with `/workbench:task "<title>"` — it allocates the ID and renders this format for you.

## ID assignment

Read `_next-id`, use it, write `id + 1` back, commit both together.

## Lifecycle

```
backlog/ -> in-development/ -> in-review/ -> verified/
                 ^_______________________| (LOCAL verification fails -> back to in-development)
decisions/  (created any time the agent needs the human; answered -> moved to backlog/)
```

## In-review cap

`ls .claude/tasks/in-review | wc -l` is bounded by the cap (default 10, set in `.workbench/config.json` as `lifecycle.in_review_cap`). When the count nears the cap (cap − 3, i.e. 7 at the default), **hard-drain**: stop taking new work and verify oldest-first (by ID) until the count is cap − 6 (i.e. 4) or lower. An unbounded in-review queue is where "done" claims pile up and the directory stops reflecting reality.
