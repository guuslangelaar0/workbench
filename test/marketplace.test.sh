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
chk "plugin declares superpowers dependency or docs fallback" "python3 - <<'PY' '$HERE/.claude-plugin/plugin.json' '$HERE/README.md'
import json, sys
pj=json.load(open(sys.argv[1]))
deps=pj.get('dependencies', [])
ok=any(isinstance(d, dict) and d.get('name')=='superpowers' and d.get('version')=='>=6.1.0' for d in deps)
docs='/plugin install superpowers@claude-plugins-official' in open(sys.argv[2]).read()
raise SystemExit(0 if (ok or docs) else 1)
PY"
PLUGIN_VERSION="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["version"])' "$HERE/.claude-plugin/plugin.json")"
MARKETPLACE_VERSION="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["plugins"][0]["version"])' "$HERE/.claude-plugin/marketplace.json")"
chk "plugin version is semver" "printf '%s\n' \"$PLUGIN_VERSION\" | grep -Eq '^[0-9]+\\.[0-9]+\\.[0-9]+$'"
chk "plugin and marketplace versions match" "[ \"$PLUGIN_VERSION\" = \"$MARKETPLACE_VERSION\" ]"
chk "changelog has current plugin version date" "grep -Eq '^## \\[$PLUGIN_VERSION\\] - [0-9]{4}-[0-9]{2}-[0-9]{2}$' '$HERE/CHANGELOG.md'"
chk "changelog names checksum assets" "grep -qi 'checksum-verified' '$HERE/CHANGELOG.md' && grep -q 'checksums.txt' '$HERE/CHANGELOG.md'"
chk "README documents Superpowers" "grep -q 'Superpowers' '$HERE/README.md' && grep -q '/plugin install superpowers@claude-plugins-official' '$HERE/README.md'"
chk "README documents verified Mesh binary acquisition" "grep -q 'checksum-verified' '$HERE/README.md' && grep -q 'checksums.txt' '$HERE/README.md'"
chk "release notes style documented for contributors" "grep -q 'vX.Y.Z — short release name' '$HERE/CONTRIBUTING.md' && grep -q 'Bug Fixes / Hardening' '$HERE/CONTRIBUTING.md' && grep -q 'auto-generated release text' '$HERE/CONTRIBUTING.md'"
chk "release notes style documented for Claude and Codex" "grep -q 'vX.Y.Z — short release name' '$HERE/CLAUDE.md' && grep -q 'vX.Y.Z — short release name' '$HERE/AGENTS.md'"
chk "release gate documented for contributors and agents" "grep -q 'scripts/release-gate.sh --live' '$HERE/CONTRIBUTING.md' && grep -q 'scripts/release-gate.sh --live' '$HERE/CLAUDE.md' && grep -q 'scripts/release-gate.sh --live' '$HERE/AGENTS.md'"

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

# --- a commands-only plugin (no skills/agents) is valid (regression: surface check
#     used to reject any single-surface plugin) ---
D6="$(mkbad '{"name":"w","version":"0.1.0","description":"d","license":"MIT"}' "$GOOD_MK" 1)"
chk "commands-only plugin is publishable" "bash '$V' '$D6' >/dev/null 2>&1"
rm -rf "$D6"

[ "$fail" = 0 ] && echo "PASS: marketplace" || { echo "marketplace test failed"; exit 1; }
