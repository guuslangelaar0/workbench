---
name: models
description: Use when spawning a teammate, engineer, verifier, or utility subagent — resolves which model to use from the project's way_of_working.models tier in .workbench/config.json. Read it before dispatching so spend matches the configured policy.
---

# Model policy

Resolve the model for any subagent/teammate from `way_of_working.models` in `.workbench/config.json`. Three tiers; the project picked one at setup. Read the config value, then apply the matching row.

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
1. Read `way_of_working.models` from `.workbench/config.json` (default `recommended` if absent).
2. Look up the role you are about to spawn in the table.
3. Pass the resolved model to the `Task` tool (or the agent-teams spawn). For `recommended`, pass nothing — `inherit` is already the agent default.

This is the policy the `orchestration` skill consults every time it dispatches an engineer or a verifier.

## Cross-model verification (optional)

A verifier on the *same* model as the implementer shares its blind spots and tends to rubber-stamp (LLM-as-judge self-enhancement bias). When `way_of_working.cross_model_verification` is `on`, the verifier must run on a model **different from the implementer**. The important part: this needs **no second tool** — a different Claude *tier* (one step up, a stronger skeptic) already breaks "the judge is the player". Codex or another provider is one option, never a requirement.

Resolve the verifier model with the helper rather than by hand:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/verifier-model.sh" \
  --implementer <model-the-engineer-used> --target "${CLAUDE_PROJECT_DIR}"
# prints:  model=<resolved>   note=<rationale>
```

- **off** (default) → the per-tier verifier from the table above. At `crew`/`fleet` the helper (with `--suggest-if-off`) files a recommend-only suggestion to turn it on.
- **on** → Codex if the `codex` dial is on; else a Claude tier one above the implementer (`sonnet`→`opus`, `haiku`→`sonnet`; if the implementer is already `opus`, use a fresh adversarial verifier context and consider enabling the `codex` dial for a genuinely different provider).

Pass the resolved `model=` to the verifier `Task` spawn. This is recommend-only to adopt — the human turns it on; the loop just surfaces the option.
