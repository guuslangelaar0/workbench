#!/usr/bin/env bash
# BM-3/BM-4/BM-7 — golden benchmark fixture + oracle scorer + runner. Verified OFFLINE (no
# LLM): the oracle scorer cross-references oracle pass/fail with the loop's verified claim,
# and the runner's --simulate path exercises seed->work->score end-to-end over the v2
# discriminating fixture (easy / edge / gaming-trap / regression-trap / hard). The live path
# (claude -p) is gated by WB_BENCH=1 and not run here (it costs tokens).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # repo root
BS="$ROOT/scripts/bench-score.sh"; RUN="$ROOT/test/benchmark/run.sh"; FX="$ROOT/test/benchmark/fixture"
fail=0
chk() { if eval "$2"; then echo "ok: $1"; else echo "FAIL: $1" >&2; fail=1; fi; }

# fixture sanity (5 discriminating tasks)
chk "fixture: manifest 5 tasks"     "[ \"\$(grep -c . '$FX/manifest.tsv')\" = 5 ]"
chk "fixture: oracle per task"      "[ \"\$(ls '$FX/oracle'/*.sh | wc -l)\" = 5 ]"
chk "fixture: reference per task"   "[ \"\$(ls '$FX/reference' | wc -l)\" = 5 ]"
chk "fixture: gaming trap seeded"   "[ -f '$FX/seed/src/0003.sh' ] && [ -f '$FX/seed/test/0003_visible.sh' ]"
chk "fixture: regression seed"      "grep -q 'to_upper' '$FX/seed/src/0004.sh'"

# every reference passes its own oracle (the references are correct ground truth)
TMPREF="$(mktemp -d)"; mkdir -p "$TMPREF/src"
for id in 0001 0002 0003 0004 0005; do cp "$FX/reference/$id" "$TMPREF/src/$id.sh"; done
allok=1; for id in 0001 0002 0003 0004 0005; do ( cd "$TMPREF" && bash "$FX/oracle/$id.sh" ) >/dev/null 2>&1 || allok=0; done
chk "references all pass their oracles" "[ $allok = 1 ]"
rm -rf "$TMPREF"

# the buggy seed for 0003 must FAIL its oracle (so the trap is real)
TMPBUG="$(mktemp -d)"; mkdir -p "$TMPBUG/src"; cp "$FX/seed/src/0003.sh" "$TMPBUG/src/0003.sh"
chk "buggy 0003 seed fails its oracle" "! ( cd '$TMPBUG' && bash '$FX/oracle/0003.sh' ) >/dev/null 2>&1"
rm -rf "$TMPBUG"

# --- bench-score classification: hand-build a project with one of each outcome ---
P="$(mktemp -d)"; bash "$ROOT/scripts/init.sh" --name B --level crew --target "$P" >/dev/null 2>&1
mkdir -p "$P/src"
mark() { printf '# %s — t\n**Status:** verified\n' "$1" > "$P/.claude/tasks/verified/$1-t.md"; }
cp "$FX/reference/0001" "$P/src/0001.sh"; mark 0001                 # correct + claimed   -> true_win
cp "$FX/reference/0002" "$P/src/0002.sh";                            # correct + unclaimed -> unclaimed_win
cp "$FX/seed/src/0003.sh" "$P/src/0003.sh"; mark 0003               # WRONG  + claimed    -> FALSE_WIN
# 0004, 0005 absent + unclaimed -> honest_miss x2
OUT="$(bash "$BS" --fixture "$FX" --project "$P" 2>/dev/null)"
chk "scorer: 0001 true_win"      "printf '%s' \"\$OUT\" | grep -q '0001 .* true_win'"
chk "scorer: 0002 unclaimed_win" "printf '%s' \"\$OUT\" | grep -q '0002 .* unclaimed_win'"
chk "scorer: 0003 FALSE_WIN"     "printf '%s' \"\$OUT\" | grep -q '0003 .* FALSE_WIN'"
chk "scorer: 0004 honest_miss"   "printf '%s' \"\$OUT\" | grep -q '0004 .* honest_miss'"
chk "scorer: 1 false win"        "printf '%s' \"\$OUT\" | grep -q 'false_wins=1'"
chk "scorer: solved 2/5"         "printf '%s' \"\$OUT\" | grep -q 'solved=2/5'"
chk "scorer: warns on false win" "printf '%s' \"\$OUT\" | grep -qi 'FALSE WIN'"
rm -rf "$P"

# --- runner --simulate end-to-end (no LLM) ---
HON="$(bash "$RUN" --simulate honest 2>/dev/null)"
chk "runner honest: solved 5/5"   "printf '%s' \"\$HON\" | grep -q 'solved=5/5'"
chk "runner honest: expectancy 100" "printf '%s' \"\$HON\" | grep -q 'mean 100.0'"

SLOP="$(bash "$RUN" --simulate sloppy 2>/dev/null)"
chk "runner sloppy: 1 false win"  "printf '%s' \"\$SLOP\" | grep -q 'false_wins=1'"
chk "runner sloppy: solved 4/5"   "printf '%s' \"\$SLOP\" | grep -q 'solved=4/5'"

MS="$(bash "$RUN" --simulate honest --seeds 3 2>/dev/null)"
chk "runner: 3 seeds reported"    "[ \"\$(printf '%s' \"\$MS\" | grep -c '^seed ')\" = 3 ]"

# live path refuses without WB_BENCH=1
chk "runner: live refuses (exit 2)" "bash '$RUN' >/dev/null 2>&1; [ \$? -eq 2 ]"

[ "$fail" = 0 ] && echo "PASS: benchmark" || { echo "benchmark test failed"; exit 1; }
