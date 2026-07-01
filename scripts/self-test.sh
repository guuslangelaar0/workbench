#!/usr/bin/env bash
# Source-repo self-test for the workbench plugin. This catches packaging and
# shell/JSON breakage before a human reloads the plugin in Claude Code.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_SUITE=1
RUN_LIVE=0
RUN_LIVE_CODING=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --skip-suite) RUN_SUITE=0; shift ;;
    --live) RUN_LIVE=1; shift ;;
    --live-coding) RUN_LIVE=1; RUN_LIVE_CODING=1; shift ;;
    *) echo "self-test.sh: unknown arg '$1'" >&2; exit 64 ;;
  esac
done

cd "$ROOT"
if [ "$RUN_LIVE" = 1 ]; then
  args=(--live)
  [ "$RUN_LIVE_CODING" = 1 ] && args+=(--live-coding)
  [ "$RUN_SUITE" = 0 ] && args+=(--skip-suite)
  exec bash "$ROOT/scripts/release-gate.sh" "${args[@]}"
fi

# python3 backs the JSON validity checks below; fail cleanly if it's absent.
command -v python3 >/dev/null 2>&1 || { echo "self-test: python3 is required for the JSON validity checks but was not found on PATH." >&2; exit 3; }

echo "workbench self-test"

json_check() {
  local path="$1"
  python3 -m json.tool "$path" >/dev/null
  echo "ok json: $path"
}

json_check ".claude-plugin/plugin.json"
json_check ".claude-plugin/marketplace.json"
json_check "hooks/hooks.json"
json_check "templates/schemas/config.schema.json"
json_check "templates/schemas/manifest.schema.json"

bash scripts/validate-plugin.sh "$ROOT" >/dev/null
echo "ok plugin: scripts/validate-plugin.sh"

for path in scripts/*.sh hooks/bin/*.sh templates/coord/*.sh templates/coord/wb-coord; do
  [ -e "$path" ] || continue
  bash -n "$path"
  echo "ok shell: $path"
done

if [ "$RUN_SUITE" = 1 ]; then
  bash test/all.sh
else
  echo "skipped suite: test/all.sh"
fi
