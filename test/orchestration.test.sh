#!/usr/bin/env bash
# Presence + content checks for the orchestration layer: skills, agents, commands,
# and the task template's Estimate field.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # workbench
S="$HERE/skills"; A="$HERE/agents"; C="$HERE/commands"
fail=0
chk() { if eval "$2"; then echo "ok: $1"; else echo "FAIL: $1" >&2; fail=1; fi; }

# --- skills ---
chk "models skill exists"           "[ -f '$S/models/SKILL.md' ]"
chk "task-lifecycle skill exists"   "[ -f '$S/task-lifecycle/SKILL.md' ]"
chk "orchestration skill exists"    "[ -f '$S/orchestration/SKILL.md' ]"

chk "models has three tiers"        "grep -q 'leaner' '$S/models/SKILL.md' && grep -q 'better' '$S/models/SKILL.md'"
chk "models warns off Haiku-reasoning" "grep -qi 'haiku' '$S/models/SKILL.md'"
chk "models reads config key"       "grep -q 'way_of_working' '$S/models/SKILL.md'"

chk "task-lifecycle covers the cap" "grep -qi 'cap' '$S/task-lifecycle/SKILL.md'"
chk "task-lifecycle uses git mv"    "grep -q 'task-move.sh' '$S/task-lifecycle/SKILL.md'"
chk "task-lifecycle: verified=done" "grep -qi 'verified' '$S/task-lifecycle/SKILL.md'"

chk "orchestration: lead never codes" "grep -qiE 'never (writes? )?codes?|lead-never-codes' '$S/orchestration/SKILL.md'"
chk "orchestration: never stop"     "grep -qiE 'never[ -]stop' '$S/orchestration/SKILL.md'"
chk "orchestration: verify gate"    "grep -qi 'verif' '$S/orchestration/SKILL.md'"
chk "orchestration: decisions queue" "grep -q 'decisions/' '$S/orchestration/SKILL.md'"
chk "orchestration: honesty triggers" "grep -qi 'honesty' '$S/orchestration/SKILL.md'"
chk "orchestration: references models skill" "grep -q 'models' '$S/orchestration/SKILL.md'"

# --- agents ---
chk "engineer agent exists"         "[ -f '$A/engineer.md' ]"
chk "verifier agent exists"         "[ -f '$A/verifier.md' ]"
chk "engineer frontmatter name"     "grep -q '^name: engineer' '$A/engineer.md'"
chk "verifier frontmatter name"     "grep -q '^name: verifier' '$A/verifier.md'"
chk "engineer inherits model"       "grep -q '^model: inherit' '$A/engineer.md'"
chk "verifier inherits model"       "grep -q '^model: inherit' '$A/verifier.md'"
chk "engineer: no Co-Authored-By"   "grep -qi 'Co-Authored-By' '$A/engineer.md'"   # must MENTION the rule (forbid it)
chk "verifier: does not fix"        "grep -qi 'do not fix\|does not fix\|not fix' '$A/verifier.md'"

# --- commands ---
for c in loop task dispatch verify mc; do
  chk "$c command exists"           "[ -f '$C/$c.md' ]"
  chk "$c has frontmatter"          "head -1 '$C/$c.md' | grep -q '^---'"
done
chk "mc command runs mc.sh"         "grep -q 'scripts/mc.sh' '$C/mc.md'"
chk "task command runs task-new.sh" "grep -q 'scripts/task-new.sh' '$C/task.md'"
chk "dispatch moves to in-development" "grep -qE 'task-move.sh|in-development' '$C/dispatch.md'"
chk "dispatch spawns engineer"      "grep -q 'engineer' '$C/dispatch.md'"
chk "verify gates to verified"      "grep -qE 'task-move.sh|verified' '$C/verify.md'"
chk "loop invokes orchestration"    "grep -qi 'orchestration' '$C/loop.md'"

# --- template + readme (built in Task 1) ---
chk "task template has Estimate token" "grep -q '{{ESTIMATE}}' '$HERE/templates/minimal/tasks/task.md.tmpl'"
chk "task README documents Estimate"   "grep -q 'Estimate' '$HERE/templates/minimal/tasks/README.md'"

[ "$fail" = 0 ] && echo "PASS: orchestration" || { echo "orchestration test failed"; exit 1; }
