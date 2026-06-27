#!/usr/bin/env bash
# Spec 4 (next layer) — automated architecture-drift assembler: aligns authored C4
# docs against graphify's extracted god-nodes. The load-bearing assertion is the
# HONESTY one: runtime/framework noise (wasm shims) must read "no" (absent from
# docs), and only genuinely-documented abstractions read "yes" — a loose matcher
# that marked wasm shims "documented" is the bug this guards against.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # workbench
S="$HERE/scripts/arch-drift.sh"
fail=0
chk() { if eval "$2"; then echo "ok: $1"; else echo "FAIL: $1" >&2; fail=1; fi; }

if ! command -v python3 >/dev/null 2>&1; then echo "SKIP: arch-drift (python3 unavailable)"; exit 0; fi

# --- solo project has no architecture backbone -> exit 2 ---
SOLO="$(mktemp -d)"; bash "$HERE/scripts/init.sh" --name "Solo" --level solo --target "$SOLO" >/dev/null 2>&1
bash "$S" "$SOLO" >/dev/null 2>&1; SOLO_RC=$?
chk "solo (no architecture dir) exits 2" "[ $SOLO_RC -eq 2 ]"
rm -rf "$SOLO"

# --- crew project WITH architecture but NO graph -> honest 'manual read', exit 0 ---
C="$(mktemp -d)"; bash "$HERE/scripts/init.sh" --name "Crew" --level crew --target "$C" >/dev/null 2>&1
OUT_NOGRAPH="$(bash "$S" "$C" 2>/dev/null)"; rc=$?
chk "no-graph: exits 0"                 "[ $rc -eq 0 ]"
chk "no-graph: says it is a manual read" "printf '%s' \"\$OUT_NOGRAPH\" | grep -qi 'manual read'"

# --- with a graph fixture: documented vs. undocumented abstractions ---
mkdir -p "$C/graphify-out"
cat > "$C/graphify-out/GRAPH_REPORT.md" <<'REP'
# Graph Report - test  (2026-06-27)
## Summary
- 100 nodes · 200 edges · 5 communities detected
## God Nodes (most connected - your core abstractions)
1. `request()` - 50 edges
2. `passArray8ToWasm0()` - 30 edges
3. `encryptedUpload()` - 20 edges
4. `SyncClient` - 12 edges
REP
# declare ONE matching container (request), ONE matching component (encryptedUpload),
# ONE multi-word match (Sync Client -> SyncClient), and ONE pure-intent component.
printf '| request | API client | TS | api |\n' >> "$C/.claude/architecture/containers.md"
printf '### api\n| encryptedUpload | upload path | core |\n| Sync Client | live sync | core |\n| Ghost Module | not built yet | none |\n' >> "$C/.claude/architecture/components.md"

OUT="$(bash "$S" "$C" 2>/dev/null)"
chk "names the extracted graph"          "printf '%s' \"\$OUT\" | grep -qi 'graphify-out/GRAPH_REPORT.md'"
chk "documented god-node reads yes (request)"        "printf '%s' \"\$OUT\" | grep -qE '^[[:space:]]*yes[[:space:]].*request\\(\\)'"
chk "documented god-node reads yes (encryptedUpload)" "printf '%s' \"\$OUT\" | grep -qE '^[[:space:]]*yes[[:space:]].*encryptedUpload\\(\\)'"
chk "multi-word doc name matches (Sync Client->SyncClient)" "printf '%s' \"\$OUT\" | grep -qE '^[[:space:]]*yes[[:space:]].*SyncClient'"
# THE honesty regression: a wasm runtime shim must NOT be reported as documented.
chk "wasm runtime shim reads no (passArray8ToWasm0)" "printf '%s' \"\$OUT\" | grep -qE '^[[:space:]]*no[[:space:]].*passArray8ToWasm0\\(\\)'"
chk "pure-intent component flagged as orphan (Ghost Module)" "printf '%s' \"\$OUT\" | grep -q 'Ghost Module'"
chk "documented component NOT flagged as orphan"     "! printf '%s' \"\$OUT\" | grep -E 'no token match' | grep -q 'encryptedUpload'"
chk "honesty caveat present (not a verdict)"         "printf '%s' \"\$OUT\" | grep -qi 'heuristic'"
rm -rf "$C"

# --- partial docs: pair level has ONLY context.md (no containers/components tables).
#     The declared-component logic runs against missing files — it must degrade
#     gracefully (exit 0, no crash), not error on the absent docs. ---
PAIR="$(mktemp -d)"; bash "$HERE/scripts/init.sh" --name "Pair" --level pair --target "$PAIR" >/dev/null 2>&1
mkdir -p "$PAIR/graphify-out"
cat > "$PAIR/graphify-out/GRAPH_REPORT.md" <<'REP'
# Graph Report - test
## Summary
- 50 nodes · 100 edges · 3 communities detected
## God Nodes (most connected - your core abstractions)
1. `request()` - 40 edges
REP
OUT_PAIR="$(bash "$S" "$PAIR" 2>/dev/null)"; PAIR_RC=$?
chk "pair (context-only docs) exits 0, no crash" "[ $PAIR_RC -eq 0 ]"
chk "pair: still emits the god-node comparison" "printf '%s' \"\$OUT_PAIR\" | grep -qi 'core abstractions'"
rm -rf "$PAIR"

[ "$fail" = 0 ] && echo "PASS: arch-drift" || { echo "arch-drift test failed"; exit 1; }
