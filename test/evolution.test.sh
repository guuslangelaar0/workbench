#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail=0
chk() { if eval "$2"; then echo "ok: $1"; else echo "FAIL: $1" >&2; fail=1; fi; }

EV="$HERE/scripts/evolve.sh"

# --- plugin-source structure ---------------------------------------------------
chk "evolve.sh exists"            "[ -f '$EV' ]"
chk "evolve command exists"       "[ -f '$HERE/commands/evolve.md' ]"
chk "evolve command has frontmatter" "head -1 '$HERE/commands/evolve.md' | grep -q '^---'"
chk "evolve command uses evolve.sh"  "grep -q 'scripts/evolve.sh' '$HERE/commands/evolve.md'"
chk "evolve command uses PLUGIN_ROOT" "grep -q 'CLAUDE_PLUGIN_ROOT' '$HERE/commands/evolve.md'"
chk "evolve command routes panel intent" "grep -qi 'convene the panel\|run a summit' '$HERE/commands/evolve.md'"
EVS="$HERE/skills/evolution/SKILL.md"
chk "evolution skill exists"          "[ -f '$EVS' ]"
chk "evolution skill has frontmatter" "head -1 '$EVS' | grep -q '^---' && grep -q '^name:' '$EVS' && grep -q '^description:' '$EVS'"
chk "evolution skill covers dual mandate" "grep -qi 'dual mandate' '$EVS' && grep -qi 'retrospective' '$EVS'"
chk "evolution skill mandates one critic" "grep -qi 'exactly one critic' '$EVS'"
chk "evolution skill reuses existing task format" "grep -q 'task-new.sh' '$EVS' && grep -q 'epic-new.sh' '$EVS'"
chk "evolution skill keeps the ledger phrase literal" "grep -q 'retrospective audit of task #NNNN' '$EVS'"
chk "orchestration wires the trigger" "grep -q 'evolve.sh' '$HERE/skills/orchestration/SKILL.md'"
chk "loop command wires the trigger"  "grep -q 'evolve.sh' '$HERE/commands/loop.md'"
chk "personas schema is valid JSON"   "python3 -m json.tool '$HERE/templates/schemas/personas.schema.json' >/dev/null"
chk "default roster is valid JSON"    "python3 -m json.tool '$HERE/templates/evolution/personas.json' >/dev/null"
chk "schema requires exactly-one-critic doc" "grep -qi 'exactly one' '$HERE/templates/schemas/personas.schema.json'"

# --- scaffold + roster validation -----------------------------------------------
P="$(mktemp -d)"; bash "$HERE/scripts/init.sh" --profile full --level crew --name evo --mission m --target "$P" >/dev/null 2>&1

chk "check without roster -> disabled" "[ \"\$(bash '$EV' check --target '$P' | head -1)\" = disabled ]"
bash "$EV" init --target "$P" >/dev/null
chk "init scaffolds roster"  "[ -f '$P/.workbench/evolution/personas.json' ]"
chk "init scaffolds ledger"  "[ -f '$P/.workbench/evolution/ideas-log.md' ]"
chk "scaffolded roster validates" "bash '$EV' validate --target '$P' >/dev/null"
chk "init is idempotent" "bash '$EV' init --target '$P' | grep 'left untouched' >/dev/null"
chk "default roster has exactly one critic" "[ \"\$(bash '$EV' roster --target '$P' | cut -f2 | grep -c '^critic\$')\" = 1 ]"
chk "default roster has generators" "bash '$EV' roster --target '$P' | cut -f2 | grep '^generator\$' >/dev/null"
chk "roster prompts survive parsing" "bash '$EV' roster --target '$P' | awk -F'\t' '\$3==\"\"{exit 1}'"

# invalid rosters are rejected (exit 2)
badcase() { # <name> <json>
  local d; d="$(mktemp -d)"; mkdir -p "$d/.workbench/evolution" "$d/.claude/tasks/backlog"
  printf '%s' "$2" > "$d/.workbench/evolution/personas.json"
  if bash "$EV" validate --target "$d" >/dev/null 2>&1; then echo "FAIL: $1 accepted" >&2; fail=1; else echo "ok: $1 rejected"; fi
  rm -rf "$d"
}
badcase "roster with no critic"   '{"personas":[{"name":"a","role":"generator","prompt":"p"}]}'
badcase "roster with two critics" '{"personas":[{"name":"a","role":"generator","prompt":"p"},{"name":"b","role":"critic","prompt":"p"},{"name":"c","role":"critic","prompt":"p"}]}'
badcase "roster with bad role"    '{"personas":[{"name":"a","role":"skeptic","prompt":"p"},{"name":"b","role":"critic","prompt":"p"}]}'
badcase "roster with empty prompt" '{"personas":[{"name":"a","role":"generator","prompt":""},{"name":"b","role":"critic","prompt":"p"}]}'
badcase "roster with duplicate names" '{"personas":[{"name":"a","role":"generator","prompt":"p"},{"name":"a","role":"critic","prompt":"p"}]}'

# parser survives escaped quotes / braces / colons inside prompts
D="$(mktemp -d)"; mkdir -p "$D/.workbench/evolution" "$D/.claude/tasks/backlog"
cat > "$D/.workbench/evolution/personas.json" <<'JSON'
{
  "queue_low_water": 5,
  "personas": [
    { "name": "gnarly", "role": "generator", "prompt": "Ask \"why?\" about {braces}, commas, and colons: all of it." },
    { "name": "critic", "role": "critic", "prompt": "Judge: kill, merge, or approve." }
  ]
}
JSON
chk "gnarly prompt parses intact" "bash '$EV' roster --target '$D' | grep 'about {braces}, commas, and colons: all of it' >/dev/null"
chk "knob override read from roster" "bash '$EV' check --target '$D' | grep 'low_water=5' >/dev/null"

# --- trigger condition -----------------------------------------------------------
chk "fresh roster -> due no-summit-yet" "[ \"\$(bash '$EV' check --target '$P' | head -1)\" = 'due no-summit-yet' ]"
bash "$EV" record-summit --target "$P" >/dev/null
chk "record-summit writes stamp"  "[ -f '$P/.workbench/evolution/last-summit' ]"
chk "record-summit heads the ledger" "grep -q '^## Summit — ' '$P/.workbench/evolution/ideas-log.md'"
chk "empty backlog after summit -> due backlog-low" "[ \"\$(bash '$EV' check --target '$P' | head -1)\" = 'due backlog-low' ]"

bash "$HERE/scripts/task-new.sh" --title "alpha" --track admin --target "$P" >/dev/null   # 0001
bash "$HERE/scripts/task-new.sh" --title "beta"  --track admin --target "$P" >/dev/null   # 0002
bash "$HERE/scripts/task-new.sh" --title "gamma" --track other --target "$P" >/dev/null   # 0003
chk "full backlog + fresh summit -> not-due" "[ \"\$(bash '$EV' check --target '$P' | head -1)\" = not-due ]"
chk "track filter counts only its track" "[ \"\$(bash '$EV' check --target '$P' --track other | head -1)\" = 'due backlog-low' ]"

# blocked tasks don't count toward the ready queue
bash "$HERE/scripts/task-new.sh" --title "delta" --track solo-track --target "$P" >/dev/null           # 0004
bash "$HERE/scripts/task-new.sh" --title "epsi"  --track solo-track --blocked-by 0004 --target "$P" >/dev/null  # 0005
chk "blocked task not counted ready" "bash '$EV' check --target '$P' --track solo-track | grep 'ready=1 ' >/dev/null"

# staleness: backdate the stamp past cadence_hours
echo "$(( $(date +%s) - 90000 ))" > "$P/.workbench/evolution/last-summit"
chk "stale summit -> due summit-stale" "[ \"\$(bash '$EV' check --target '$P' | head -1)\" = 'due summit-stale' ]"
bash "$EV" record-summit --target "$P" >/dev/null
chk "re-recording resets staleness" "[ \"\$(bash '$EV' check --target '$P' | head -1)\" = not-due ]"

# --- ledger + retrospective rotation ----------------------------------------------
bash "$EV" log --persona product-visionary --idea "pool rebalance wizard" --disposition "queued as task #0006" --target "$P" >/dev/null
chk "ledger entry format" "grep -qE '^- \[[0-9]{4}-[0-9]{2}-[0-9]{2}\] product-visionary — pool rebalance wizard — queued as task #0006\$' '$P/.workbench/evolution/ideas-log.md'"
bash "$EV" log --persona panel --idea $'multi\nline\tidea' --disposition "deferred: later" --target "$P" >/dev/null
chk "ledger entries stay one line" "[ \"\$(grep -cE '^- \[[0-9]{4}-' '$P/.workbench/evolution/ideas-log.md')\" = 2 ]"
chk "log requires disposition" "! bash '$EV' log --persona x --idea y --target '$P' >/dev/null 2>&1"

# verified/shipped rotation: 0001+0002 audited, 0003 not
mkdir -p "$P/.claude/tasks/verified" "$P/.claude/tasks/shipped"
mv "$P"/.claude/tasks/backlog/0001-*.md "$P/.claude/tasks/verified/"
mv "$P"/.claude/tasks/backlog/0002-*.md "$P/.claude/tasks/shipped/"
mv "$P"/.claude/tasks/backlog/0003-*.md "$P/.claude/tasks/verified/"
bash "$EV" log --persona panel --idea "re-examined alpha" --disposition "retrospective audit of task #0001: approved as-is" --target "$P" >/dev/null
bash "$EV" log --persona panel --idea "re-examined beta" --disposition "retrospective audit of task #0002: expand — queued as task #0007" --target "$P" >/dev/null
chk "audited extracts covered ids" "[ \"\$(bash '$EV' audited --target '$P' | tr '\n' ' ')\" = '0001 0002 ' ]"
chk "retro-candidates skips audited, oldest first" "[ \"\$(bash '$EV' retro-candidates --target '$P' | head -1)\" = 0003 ]"
chk "retro-candidates excludes audited ids" "! bash '$EV' retro-candidates --target '$P' | grep '^0001\$' >/dev/null"
chk "retro-candidates respects --limit" "[ \"\$(bash '$EV' retro-candidates --target '$P' --limit 1 | wc -l | tr -d ' ')\" = 1 ]"
chk "retro-candidates track filter" "[ -z \"\$(bash '$EV' retro-candidates --target '$P' --track admin)\" ]"

# --- synthesis produces a well-formed task in the existing format ------------------
OUT="$(bash "$HERE/scripts/task-new.sh" --title "panel: pool rebalance wizard" --track admin \
  --verification "cargo test passes + wizard flow screenshot" --target "$P")"
TF="$(printf '%s' "$OUT" | sed -n 's/^workbench: created \(.*\) (id .*/\1/p')"
chk "synthesized task file exists" "[ -f '$TF' ]"
chk "synthesized task has canonical fields" "grep -q '^\*\*Track:\*\* admin\$' '$TF' && grep -q '^\*\*Verification:\*\*' '$TF' && grep -q '^## Acceptance criteria\$' '$TF' && grep -q '^## Verification ladder\$' '$TF'"
chk "synthesized task lands in backlog" "dirname '$TF' | grep '/.claude/tasks/backlog\$' >/dev/null"

rm -rf "$P" "$D"
[ "$fail" = 0 ] && echo "PASS: evolution" || { echo "evolution test failed"; exit 1; }
