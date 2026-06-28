---
description: Verify a task's declared verification and gate it to verified/ (or back to in-development/)
allowed-tools: ["Bash", "Read", "Task", "TodoWrite"]
argument-hint: "<id>"
---

Run the verification gate for a task. Follow the `orchestration` and `task-lifecycle` skills.

1. Parse the task `<id>` from `$ARGUMENTS`. Read its **verification contract** — the `**Verification:**` field, the `## Acceptance criteria`, the `## Scenarios`, and the `## Verification ladder`. These define "done"; they should have been written before dispatch.
2. Apply the gate per `way_of_working.verification` in `.workbench/config.json`:
   - `leaner` — run the verification yourself (the engineer already self-verified); spot-check.
   - `recommended` — spawn a `verifier` (Task tool, `subagent_type: verifier`, model per the `models` skill) to independently run it and return evidence.
   - `better` — spawn several verifiers with an adversarial framing; require a majority PASS.
   Always: review the diff, build, and run the declared verification before advancing.
2.5. **Anti-gaming check.** Before advancing, inspect the task's code diff for reward-hacking — a test deleted, skipped/ignored, or weakened to a trivial pass while the task claims its tests are green. Run the guard over the task's commit range (the range the engineer's work landed in, e.g. the baseline the task started from to `HEAD`):
   `bash "${CLAUDE_PLUGIN_ROOT}/scripts/gate-integrity.sh" --range <baseline>..HEAD --task <task-file> --key gaming-<id> --target "${CLAUDE_PROJECT_DIR}"`
   It is a HEURISTIC — it raises honest suspicion, it does not certify. It files a `warn` suggestion on anything it finds and **exits 3 (block)** when a hard signal (deleted/skipped/trivial test) coincides with a pass-claim at `crew`/`fleet`. If it blocks or flags, review the diff: if the change is legitimate (e.g. an obsolete test removed) note why and proceed; otherwise bounce the task to `in-development`.
3. **On PASS** — capture the evidence (command output / screenshot path / commit SHA) into the task's `## Verification evidence` section, then move it:
   `bash "${CLAUDE_PLUGIN_ROOT}/scripts/task-move.sh" <id> verified --target "${CLAUDE_PROJECT_DIR}"`
   (Use `staged` instead of `verified` when the level's lifecycle includes a `staged` stage — Crew and Fleet are deploy-gated — and a prod deploy is still pending.)
   `task-move.sh` runs the **verification-contract gate** on any move into `verified`/`staged`/`shipped`: at `crew`+ it **refuses** the move unless real acceptance criteria *and* a populated `## Verification evidence` section exist (`scripts/verify-gate.sh`; advisory at `solo`/`pair`; `WB_SKIP_VERIFY_GATE=1` overrides the rare legit case). So capture evidence *first* — "verified" is structurally unfakeable.
4. **On FAIL** — note exactly what's missing in `## Notes`, then move it back:
   `bash "${CLAUDE_PLUGIN_ROOT}/scripts/task-move.sh" <id> in-development --target "${CLAUDE_PROJECT_DIR}"`

Report the verdict honestly with the evidence. Only `verified/` (or `shipped/`) with evidence is "done."
