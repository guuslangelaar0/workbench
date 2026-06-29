#!/usr/bin/env bash
# workbench EXPECTANCY / CONFORMANCE GATE — a regression gate for the WAY OF WORKING itself.
# A change to a skill, a command description, the intent-routing table, or a dial can quietly
# make the loop behave worse. This blocks that.
#
# Two tiers:
#   (default, FREE, every CI run) structural conformance invariants — the things the live
#     conformance score depends on must still be present: the intent-routing table in the
#     scaffolded CLAUDE.md, routing keywords in the mc/suggest descriptions, a non-empty
#     description on every command and skill, and the conformance harness itself still scoring
#     5/5 in --simulate (oracles ↔ simulators in sync). Exit 1 if any invariant is broken.
#   (--live, PAID, on cadence) runs the real intent-conformance benchmark (claude -p) and fails
#     if conformance dropped below the committed baseline (test/benchmark/baseline).
#     --update-baseline records the current live conformance as the new floor.
#
# Usage: expectancy-gate.sh [--live] [--update-baseline]
set -uo pipefail
ROOT="${WB_GATE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
LIVE=0 UPDATE=0
for a in "$@"; do case "$a" in
  --live) LIVE=1 ;; --update-baseline) UPDATE=1 ;;
  *) echo "expectancy-gate.sh: unknown arg '$a'" >&2; exit 64 ;;
esac; done
BASELINE="$ROOT/test/benchmark/baseline"
fail=0
ok(){ printf '  ok   %s\n' "$1"; }
no(){ printf '  FAIL %s\n' "$1" >&2; fail=1; }

echo "structural conformance invariants:"
# 1. intent-routing table in both scaffolded CLAUDE.md templates
for t in full minimal; do
  if grep -qi 'Intent routing' "$ROOT/templates/$t/CLAUDE.md.tmpl" 2>/dev/null; then ok "routing table present in $t CLAUDE.md"; else no "routing table MISSING in $t CLAUDE.md"; fi
done
# 2. routing keywords in the descriptions that drive tool selection
grep -qiE 'status|overview|where do things stand' "$ROOT/commands/mc.md"   && ok "mc description has status/overview routing"   || no "mc description lost its status/overview routing keywords"
grep -qiE 'idea'                                   "$ROOT/commands/suggest.md" && ok "suggest description names 'idea'"          || no "suggest description lost the feature-idea routing keyword"
# 3. every command + skill has a non-empty description (the SlashCommand/skill routing signal)
miss=0
for f in "$ROOT"/commands/*.md; do
  d="$(sed -n 's/^description:[[:space:]]*//p' "$f" | head -1)"
  [ -n "$d" ] || { miss=1; printf '       (no description: %s)\n' "${f#$ROOT/}" >&2; }
done
[ "$miss" = 0 ] && ok "every command has a description" || no "a command is missing its description"
miss=0
for f in "$ROOT"/skills/*/SKILL.md; do
  d="$(sed -n 's/^description:[[:space:]]*//p' "$f" | head -1)"
  [ -n "$d" ] || { miss=1; printf '       (no description: %s)\n' "${f#$ROOT/}" >&2; }
done
[ "$miss" = 0 ] && ok "every skill has a description" || no "a skill is missing its description"
# 4. the conformance harness itself still scores 5/5 in simulate (oracles ↔ simulators aligned)
sim="$(bash "$ROOT/scripts/bench-intents.sh" --simulate 2>/dev/null | sed -n 's/.*conformance=\([0-9]*\/[0-9]*\).*/\1/p')"
if [ "${sim%/*}" = "${sim#*/}" ] && [ -n "$sim" ]; then ok "conformance harness intact (simulate $sim)"; else no "conformance harness broken (simulate $sim — oracles/simulators out of sync)"; fi

if [ "$LIVE" = 1 ]; then
  echo "live conformance (claude -p — costs tokens):"
  if [ "${WB_BENCH:-0}" != 1 ]; then echo "  (set WB_BENCH=1 to run the live gate)"; else
    live="$(bash "$ROOT/scripts/bench-intents.sh" 2>/dev/null | sed -n 's/.*expectancy=\([0-9]*\).*/\1/p')"; live="${live:-0}"
    base="$(tr -d ' \n' < "$BASELINE" 2>/dev/null)"; case "$base" in ''|*[!0-9]*) base=0 ;; esac
    echo "  live conformance: $live  ·  baseline: $base"
    if [ "$UPDATE" = 1 ]; then echo "$live" > "$BASELINE"; ok "baseline updated to $live"
    elif [ "$live" -lt "$base" ]; then no "live conformance $live dropped below baseline $base — a change made the loop behave worse"
    else ok "live conformance $live >= baseline $base"; fi
  fi
fi

echo "─────────────────────────────────────────────"
[ "$fail" = 0 ] && { echo "expectancy-gate: PASS"; exit 0; } || { echo "expectancy-gate: FAIL — the way of working regressed"; exit 1; }
