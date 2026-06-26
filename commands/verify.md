---
description: Verify a task's declared verification and gate it to verified/ (or back to in-development/)
allowed-tools: ["Bash", "Read", "Task", "TodoWrite"]
argument-hint: "<id>"
---

Run the verification gate for a task. Follow the `orchestration` and `task-lifecycle` skills.

1. Parse the task `<id>` from `$ARGUMENTS`. Read its `**Verification:**` field and acceptance criteria.
2. Apply the gate per `way_of_working.verification` in `.initlab/config.json`:
   - `leaner` — run the verification yourself (the engineer already self-verified); spot-check.
   - `recommended` — spawn a `verifier` (Task tool, `subagent_type: verifier`, model per the `models` skill) to independently run it and return evidence.
   - `better` — spawn several verifiers with an adversarial framing; require a majority PASS.
   Always: review the diff, build, and run the declared verification before advancing.
3. **On PASS** — capture the evidence (command output / screenshot path) into the task's `## Verification evidence` section, then move it:
   `bash "${CLAUDE_PLUGIN_ROOT}/scripts/task-move.sh" <id> verified --target "${CLAUDE_PROJECT_DIR}"`
   (Use `ready-to-ship` instead of `verified` if `lifecycle.deploy_gated` is true and a prod deploy is still pending.)
4. **On FAIL** — note exactly what's missing in `## Notes`, then move it back:
   `bash "${CLAUDE_PLUGIN_ROOT}/scripts/task-move.sh" <id> in-development --target "${CLAUDE_PROJECT_DIR}"`

Report the verdict honestly with the evidence. Only `verified/` (or `shipped/`) with evidence is "done."
