#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail=0
chk() { if eval "$2"; then echo "ok: $1"; else echo "FAIL: $1" >&2; fail=1; fi; }
VERSION="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$HERE/.claude-plugin/plugin.json" | head -1)"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

UNCONFIGURED="$TMP/unconfigured"
mkdir -p "$UNCONFIGURED"
out_unconfigured="$(bash "$HERE/scripts/hooks-mode.sh" status --target "$UNCONFIGURED" --plugin-root "$HERE" 2>/dev/null || true)"
chk "unconfigured reports unconfigured" "printf '%s' \"\$out_unconfigured\" | grep -q '^state=unconfigured$'"

ENABLED="$TMP/enabled"
mkdir -p "$ENABLED"
bash "$HERE/scripts/init.sh" --profile full --name "HooksEnabled" --mission "m" --target "$ENABLED" --hooks enabled >/dev/null 2>&1
out_enabled="$(bash "$HERE/scripts/hooks-mode.sh" status --target "$ENABLED" --plugin-root "$HERE")"
chk "fresh init records hooks enabled" "python3 - <<PY
import json
d=json.load(open('$ENABLED/.workbench/config.json'))
assert d['workbench']['hooks']['mode'] == 'enabled'
assert d['workbench']['hooks']['version'] == '$VERSION'
PY"
chk "enabled status is current" "printf '%s' \"\$out_enabled\" | grep -q '^state=enabled$'"

bash "$HERE/scripts/hooks-mode.sh" disable --target "$ENABLED" --plugin-root "$HERE" >/dev/null
out_disabled="$(bash "$HERE/scripts/hooks-mode.sh" status --target "$ENABLED" --plugin-root "$HERE")"
chk "disable records disabled choice" "python3 - <<PY
import json
d=json.load(open('$ENABLED/.workbench/config.json'))
assert d['workbench']['hooks']['mode'] == 'disabled'
assert d['workbench']['hooks']['version'] == '$VERSION'
PY"
chk "disabled status is disabled-by-choice" "printf '%s' \"\$out_disabled\" | grep -q '^state=disabled$'"

bash "$HERE/scripts/hooks-mode.sh" enable --target "$ENABLED" --plugin-root "$HERE" >/dev/null
out_reenabled="$(bash "$HERE/scripts/hooks-mode.sh" status --target "$ENABLED" --plugin-root "$HERE")"
chk "enable records enabled choice" "python3 - <<PY
import json
d=json.load(open('$ENABLED/.workbench/config.json'))
assert d['workbench']['hooks']['mode'] == 'enabled'
assert d['workbench']['hooks']['version'] == '$VERSION'
PY"
chk "reenabled status is enabled" "printf '%s' \"\$out_reenabled\" | grep -q '^state=enabled$'"

SKIPPED="$TMP/skipped"
mkdir -p "$SKIPPED"
bash "$HERE/scripts/init.sh" --profile full --name "HooksSkipped" --mission "m" --target "$SKIPPED" --hooks disabled >/dev/null 2>&1
out_skipped="$(bash "$HERE/scripts/hooks-mode.sh" status --target "$SKIPPED" --plugin-root "$HERE")"
chk "init can record hooks disabled" "printf '%s' \"\$out_skipped\" | grep -q '^state=disabled$'"

MISSING="$TMP/missing"
mkdir -p "$MISSING/.workbench"
cat > "$MISSING/.workbench/config.json" <<'JSON'
{
  "workbench": { "version": "0.0.1", "initialized_at": "x", "level": "solo" },
  "project": { "name": "MissingHooks", "kind": "existing" },
  "way_of_working": {
    "models": "recommended",
    "verification": "recommended",
    "review": "recommended",
    "parallelism": "recommended",
    "enforcement": "warn-default",
    "continuity": "recommended",
    "graphify": "off",
    "codex": "off",
    "remote": "off",
    "inception_depth": "recommended"
  },
  "lifecycle": { "in_review_cap": 10 }
}
JSON
out_missing="$(bash "$HERE/scripts/hooks-mode.sh" status --target "$MISSING" --plugin-root "$HERE")"
chk "missing hook preference is reported" "printf '%s' \"\$out_missing\" | grep -q '^state=missing$'"

STALE="$TMP/stale"
mkdir -p "$STALE"
bash "$HERE/scripts/init.sh" --profile full --name "HooksStale" --mission "m" --target "$STALE" --hooks enabled >/dev/null 2>&1
python3 - <<PY
import json
p='$STALE/.workbench/config.json'
d=json.load(open(p))
d['workbench']['hooks']['version']='0.0.0'
open(p,'w').write(json.dumps(d, indent=2) + '\\n')
PY
out_stale="$(bash "$HERE/scripts/hooks-mode.sh" status --target "$STALE" --plugin-root "$HERE")"
chk "stale hook preference is reported" "printf '%s' \"\$out_stale\" | grep -q '^state=stale$'"

MALFORMED="$TMP/malformed"
mkdir -p "$MALFORMED/.workbench"
printf '{ not json\n' > "$MALFORMED/.workbench/config.json"
bash "$HERE/scripts/hooks-mode.sh" enable --target "$MALFORMED" --plugin-root "$HERE" >/tmp/workbench-hooks-mode.err 2>&1
rc=$?
chk "malformed config refuses mutation" "[ \"$rc\" -ne 0 ] && grep -qi 'invalid config json' /tmp/workbench-hooks-mode.err"

[ "$fail" = 0 ] && echo "PASS: hooks-mode" || { echo "hooks-mode test failed"; exit 1; }
