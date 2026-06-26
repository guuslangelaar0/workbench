#!/usr/bin/env bash
# Presence + content checks for the inception wizard: the scope-control OUT-gate,
# composition (brainstorming / grill-me / frontend-design), the genesis sequence,
# the output (spec + seeded backlog + Mermaid), and depth tiers.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # tools/initlab
S="$HERE/skills"; C="$HERE/commands"
fail=0
chk() { if eval "$2"; then echo "ok: $1"; else echo "FAIL: $1" >&2; fail=1; fi; }

# --- skill presence ---
chk "inception skill exists"            "[ -f '$S/inception/SKILL.md' ]"
chk "inception has frontmatter name"    "grep -q '^name: inception' '$S/inception/SKILL.md'"

# --- the hard scope gate (the whole point) ---
chk "inception names an OUT/scope cut"  "grep -qiE 'out of (v1 |)scope|v1 OUT|explicitly out|not building' '$S/inception/SKILL.md'"
chk "inception REFUSES without OUT"      "grep -qiE 'refuse|do not proceed|may not proceed|will not proceed|won.t proceed' '$S/inception/SKILL.md'"
chk "inception names v1 IN list"         "grep -qiE 'v1 IN|in scope|smallest set' '$S/inception/SKILL.md'"

# --- composition (process skills first) ---
chk "inception composes brainstorming"   "grep -q 'superpowers:brainstorming' '$S/inception/SKILL.md'"
chk "inception (better) composes grill-me" "grep -q 'grill-me' '$S/inception/SKILL.md'"
chk "inception design phase"             "grep -qiE 'frontend-design|figma' '$S/inception/SKILL.md'"

# --- the genesis sequence ---
chk "inception covers repos/topology"    "grep -qiE 'repo|topology' '$S/inception/SKILL.md'"
chk "inception covers delivery"          "grep -qiE 'github|ci/cd|ci |deploy' '$S/inception/SKILL.md'"

# --- output + handoff ---
chk "inception outputs a spec"           "grep -qi 'spec' '$S/inception/SKILL.md'"
chk "inception requires Mermaid"         "grep -qi 'mermaid' '$S/inception/SKILL.md'"
chk "inception seeds the backlog"        "grep -qiE 'seed the backlog|/initlab:task|seed .* backlog' '$S/inception/SKILL.md'"
chk "inception hands off to the loop"    "grep -q '/initlab:loop' '$S/inception/SKILL.md'"

# --- depth tiers ---
chk "inception reads inception_depth"    "grep -q 'inception_depth' '$S/inception/SKILL.md'"
chk "inception has leaner+better tiers"  "grep -q 'leaner' '$S/inception/SKILL.md' && grep -q 'better' '$S/inception/SKILL.md'"

# --- command ---
chk "inception command exists"           "[ -f '$C/inception.md' ]"
chk "inception command frontmatter"      "head -1 '$C/inception.md' | grep -q '^---'"
chk "inception command invokes the skill" "grep -qi 'inception' '$C/inception.md'"
chk "inception command holds the gate"   "grep -qiE 'OUT|out of scope|refuse|do not proceed' '$C/inception.md'"

[ "$fail" = 0 ] && echo "PASS: inception" || { echo "inception test failed"; exit 1; }
