#!/usr/bin/env bash
# Spec 5 — marketplace distribution: the plugin manifests are valid, consistent, and
# publishable, and validate-plugin.sh actually catches the failure modes it claims to.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # workbench
V="$HERE/scripts/validate-plugin.sh"
fail=0
chk() { if eval "$2"; then echo "ok: $1"; else echo "FAIL: $1" >&2; fail=1; fi; }

if ! command -v python3 >/dev/null 2>&1; then echo "SKIP: marketplace (python3 unavailable)"; exit 0; fi

# --- the real plugin is publishable ---
chk "real plugin validates (exit 0)"   "bash '$V' '$HERE' >/dev/null 2>&1"
chk "validator reports publishable"     "bash '$V' '$HERE' 2>/dev/null | grep -q publishable"
chk "license is MIT, not Proprietary"   "grep -q '\"license\": \"MIT\"' '$HERE/.claude-plugin/plugin.json' && ! grep -qi 'proprietary' '$HERE/.claude-plugin/plugin.json'"
chk "homepage is not stale (beebeeb)"   "! grep -qi 'beebeeb' '$HERE/.claude-plugin/plugin.json'"
chk "LICENSE file exists + is MIT"      "[ -f '$HERE/LICENSE' ] && grep -qi 'MIT License' '$HERE/LICENSE'"

# --- negatives: the validator must REJECT broken manifests ---
mkbad() { # builds a temp plugin dir; $1 = plugin.json body, $2 = marketplace.json body, $3 = write LICENSE? (1/0)
  local d; d="$(mktemp -d)"; mkdir -p "$d/.claude-plugin" "$d/commands"
  printf '%s' "$1" > "$d/.claude-plugin/plugin.json"
  printf '%s' "$2" > "$d/.claude-plugin/marketplace.json"
  echo "x" > "$d/commands/x.md"
  [ "${3:-1}" = 1 ] && printf 'MIT License\n' > "$d/LICENSE"
  printf '%s' "$d"
}
GOOD_MK='{"name":"w","owner":{"name":"x"},"plugins":[{"name":"w","source":".","version":"0.1.0"}]}'

D1="$(mkbad '{"name":"w","version":"0.1.0","description":"d","license":"Proprietary"}' "$GOOD_MK" 1)"
chk "rejects Proprietary license"       "! bash '$V' '$D1' >/dev/null 2>&1"
D2="$(mkbad '{"name":"w","version":"0.2.0","description":"d","license":"MIT"}' "$GOOD_MK" 1)"
# capture-then-grep: validate exits non-zero, and `validate | grep` under pipefail would
# propagate that exit even when grep matches — so grab the output first.
D2_OUT="$(bash "$V" "$D2" 2>/dev/null || true)"
chk "rejects version mismatch"          "printf '%s' \"\$D2_OUT\" | grep -q 'version mismatch'"
D3="$(mkbad '{"name":"w","version":"0.1.0","description":"d","license":"MIT"}' "$GOOD_MK" 0)"
chk "rejects missing LICENSE file"      "! bash '$V' '$D3' >/dev/null 2>&1"
D4="$(mkbad '{"name":"w","version":"0.1.0","license":"MIT"}' "$GOOD_MK" 1)"
chk "rejects missing description"       "! bash '$V' '$D4' >/dev/null 2>&1"
D5="$(mkbad '{"name":"w" "version":}' "$GOOD_MK" 1)"
chk "rejects invalid JSON"              "! bash '$V' '$D5' >/dev/null 2>&1"
rm -rf "$D1" "$D2" "$D3" "$D4" "$D5"

[ "$fail" = 0 ] && echo "PASS: marketplace" || { echo "marketplace test failed"; exit 1; }
