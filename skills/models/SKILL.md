---
name: models
description: Use when spawning a teammate, engineer, verifier, or utility subagent — resolves which model to use from the project's way_of_working.models tier in .initlab/config.json. Read it before dispatching so spend matches the configured policy.
---

# Model policy

Resolve the model for any subagent/teammate from `way_of_working.models` in `.initlab/config.json`. Three tiers; the project picked one at setup. Read the config value, then apply the matching row.

| Role | `leaner` (cheaper) | `recommended` (default) | `better` (pricier) |
|---|---|---|---|
| Lead (this session) | session model; Opus only for the hardest reasoning | session model (inherit) | Opus |
| Engineer (implementer) | Sonnet | inherit session model | Opus |
| Verifier | Sonnet | inherit session model | Opus |
| Utility / short-lived (file moves, formatting, greps) | Haiku | Sonnet | Sonnet |

## Hard rules (all tiers)
- **Never Haiku for reasoning.** Haiku is only for the most mechanical utility work, and only in `leaner`. Code implementation, verification, and review always use Sonnet or better.
- **Engineers and verifiers default to `inherit`** (the agent files declare `model: inherit`). When the tier calls for a different model, pass it explicitly when you spawn — `Task(subagent_type: engineer, model: <resolved>)` — rather than editing the agent file.
- **When unsure, round up, not down.** A correctness miss costs more than the model delta. Opus for genuinely hard or risky work regardless of tier.

## How to apply
1. Read `way_of_working.models` from `.initlab/config.json` (default `recommended` if absent).
2. Look up the role you are about to spawn in the table.
3. Pass the resolved model to the `Task` tool (or the agent-teams spawn). For `recommended`, pass nothing — `inherit` is already the agent default.

This is the policy the `orchestration` skill consults every time it dispatches an engineer or a verifier.
