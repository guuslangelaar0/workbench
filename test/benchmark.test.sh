#!/usr/bin/env bash
# BM-3/BM-4 — golden benchmark fixture + oracle scorer + runner. Verified OFFLINE (no LLM):
# the oracle scorer cross-references oracle pass/fail with the loop's verified claim, and the
# runner's --simulate path exercises seed→work→score end-to-end. The live path (claude -p) is
# gated by WB_BENCH=1 and not run here (it costs tokens) — but the runner refuses without it.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # repo root
BS="$ROOT/scripts/bench-score.sh"; RUN="$ROOT/test/benchmark/run.sh"; FX="$ROOT/test/benchmark/fixture"
fail=0
chk() { if eval "$2"; then echo "ok: $1"; else echo "FAIL: $1" >&2; fail=1; fi; }

# fixture sanity
chk "fixture: manifest exists"      "[ -f '$FX/manifest.tsv' ]"
chk "fixture: 3 tasks"              "[ \"\$(grep -c . '$FX/manifest.tsv')\" = 3 ]"
chk "fixture: oracle+ref per task"  "[ \"\$(ls '$FX/oracle'/*.sh | wc -l)\" = 3 ] && [ \"\$(ls '$FX/reference' | wc -l)\" = 3 ]"

# --- bench-score directly: build a project by hand and check each classification ---
P="$(mktemp -d)"; bash "$ROOT/scripts/init.sh" --name B --level crew --target "$P" >/dev/null 2>&1
mkdir -p "$P/artifacts"
seed_task() { printf '# %s — t\n**Status:** %s\n' "$1" "$2" > "$P/.claude/tasks/$2/$1-t.md"; }

# 0001 correct + verified = true_win ; 0002 correct but NOT claimed = unclaimed_win ;
# 0003 WRONG but verified = FALSE_WIN
cp "$FX/reference/0001" "$P/artifacts/greeting.txt"; seed_task 0001 verified
cp "$FX/reference/0002" "$P/artifacts/sum.txt";      # not claimed (stays absent from verified)
printf 'WRONG\n' > "$P/artifacts/rev.txt";           seed_task 0003 verified
OUT="$(bash "$BS" --fixture "$FX" --project "$P" 2>/dev/null)"
chk "scorer: 0001 true_win"      "printf '%s' \"\$OUT\" | grep -q '0001 .* true_win'"
chk "scorer: 0002 unclaimed_win" "printf '%s' \"\$OUT\" | grep -q '0002 .* unclaimed_win'"
chk "scorer: 0003 FALSE_WIN"     "printf '%s' \"\$OUT\" | grep -q '0003 .* FALSE_WIN'"
chk "scorer: reports 1 false win" "printf '%s' \"\$OUT\" | grep -q 'false_wins=1'"
# net = 1*100(true) + 1*60(unclaimed) - 1*150(false) - 0 = 10 ; /3 = 3.3
chk "scorer: expectancy 3.3"     "printf '%s' \"\$OUT\" | grep -q 'expectancy=3.3'"
chk "scorer: warns on false win" "printf '%s' \"\$OUT\" | grep -qi 'FALSE WIN'"
rm -rf "$P"

# all-correct-and-claimed = perfect
P2="$(mktemp -d)"; bash "$ROOT/scripts/init.sh" --name B2 --level crew --target "$P2" >/dev/null 2>&1
mkdir -p "$P2/artifacts"
for id in 0001 0002 0003; do
  art="$(awk -F'\t' -v i="$id" '$1==i{print $3}' "$FX/manifest.tsv")"
  cp "$FX/reference/$id" "$P2/$art"; printf '# %s — t\n**Status:** verified\n' "$id" > "$P2/.claude/tasks/verified/$id-t.md"
done
chk "scorer: perfect -> expectancy 100" "bash '$BS' --fixture '$FX' --project '$P2' --quiet 2>/dev/null | grep -q '^100.0\$'"
rm -rf "$P2"

# --- runner --simulate (end-to-end seed->work->score, no LLM) ---
HON="$(bash "$RUN" --simulate honest 2>/dev/null)"
chk "runner honest: solved 3/3"   "printf '%s' \"\$HON\" | grep -q 'solved=3/3'"
chk "runner honest: 0 false wins" "printf '%s' \"\$HON\" | grep -q 'false_wins=0'"
chk "runner honest: mean line"    "printf '%s' \"\$HON\" | grep -q 'BENCHMARK expectancy: mean 100.0'"

SLOP="$(bash "$RUN" --simulate sloppy 2>/dev/null)"
chk "runner sloppy: 1 false win"  "printf '%s' \"\$SLOP\" | grep -q 'false_wins=1'"
chk "runner sloppy: solved 2/3"   "printf '%s' \"\$SLOP\" | grep -q 'solved=2/3'"

# multi-seed mean line present
MS="$(bash "$RUN" --simulate honest --seeds 3 2>/dev/null)"
chk "runner: 3 seeds reported"    "[ \"\$(printf '%s' \"\$MS\" | grep -c '^seed ')\" = 3 ]"

# live path refuses without WB_BENCH=1
chk "runner: live refuses (exit 2)" "bash '$RUN' >/dev/null 2>&1; [ \$? -eq 2 ]"

[ "$fail" = 0 ] && echo "PASS: benchmark" || { echo "benchmark test failed"; exit 1; }
