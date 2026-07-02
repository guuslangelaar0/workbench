#!/usr/bin/env bash
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SELF_DIR/.." && pwd)"
. "$SELF_DIR/lib.sh"

cmd="${1:-}"
[ -n "$cmd" ] || { echo "usage: hooks-mode.sh status|enable|disable --target DIR [--plugin-root DIR]" >&2; exit 64; }
shift

TARGET="$PWD"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --target)
      [ "$#" -ge 2 ] || { echo "hooks-mode.sh: --target requires a value" >&2; exit 64; }
      TARGET="$2"; shift 2 ;;
    --plugin-root)
      [ "$#" -ge 2 ] || { echo "hooks-mode.sh: --plugin-root requires a value" >&2; exit 64; }
      PLUGIN_ROOT="$2"; shift 2 ;;
    *)
      echo "hooks-mode.sh: unknown arg '$1'" >&2; exit 64 ;;
  esac
done

plugin_version() {
  sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$PLUGIN_ROOT/.claude-plugin/plugin.json" | head -1
}

CFG="$(il_cfg_dir "$TARGET")/config.json"
PV="$(plugin_version)"
[ -n "$PV" ] || { echo "hooks-mode.sh: could not read plugin version" >&2; exit 1; }

if [ ! -f "$CFG" ]; then
  if [ "$cmd" = status ]; then
    printf 'state=unconfigured\nmode=unknown\nversion=\nplugin_version=%s\n' "$PV"
    exit 0
  fi
  echo "hooks-mode.sh: project is not configured; run /workbench:workbench first" >&2
  exit 65
fi

case "$cmd" in
  status)
    python3 - "$CFG" "$PV" <<'PY'
import json, sys
path, plugin_version = sys.argv[1], sys.argv[2]
try:
    data = json.load(open(path))
except Exception:
    print("state=invalid")
    print("mode=unknown")
    print("version=")
    print(f"plugin_version={plugin_version}")
    sys.exit(0)

hooks = data.get("workbench", {}).get("hooks")
if not isinstance(hooks, dict):
    print("state=missing")
    print("mode=missing")
    print("version=")
    print(f"plugin_version={plugin_version}")
    sys.exit(0)

mode = hooks.get("mode", "")
version = hooks.get("version", "")
if mode == "disabled":
    state = "disabled"
elif mode == "enabled" and version == plugin_version:
    state = "enabled"
elif mode == "enabled":
    state = "stale"
else:
    state = "missing"

print(f"state={state}")
print(f"mode={mode or 'missing'}")
print(f"version={version}")
print(f"plugin_version={plugin_version}")
PY
    ;;
  enable|disable)
    mode="enabled"
    [ "$cmd" = disable ] && mode="disabled"
    tmp="$CFG.tmp.$$"
    if ! python3 - "$CFG" "$tmp" "$mode" "$PV" <<'PY'
import json, sys, datetime
src, dst, mode, version = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
try:
    data = json.load(open(src))
except Exception as exc:
    print(f"hooks-mode.sh: invalid config json: {exc}", file=sys.stderr)
    sys.exit(2)

workbench = data.setdefault("workbench", {})
workbench["hooks"] = {
    "mode": mode,
    "version": version,
    "updated_at": datetime.datetime.now(datetime.UTC).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
}
open(dst, "w").write(json.dumps(data, indent=2) + "\n")
PY
    then
      rm -f "$tmp"
      exit 1
    fi
    mv "$tmp" "$CFG"
    printf 'hooks=%s\n' "$mode"
    ;;
  *)
    echo "usage: hooks-mode.sh status|enable|disable --target DIR [--plugin-root DIR]" >&2
    exit 64 ;;
esac
