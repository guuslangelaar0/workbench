#!/usr/bin/env bash
# workbench drift classifier. Reads <project>/.workbench/manifest.json (or legacy
# .workbench/manifest.json from a migrated project), recomputes each managed file's sha256, and prints:
# <path>  <mode>  <status>
# status = ok (matches recorded hash) | edited (differs) | missing.
# Dev-time tooling: python3 is used to parse the manifest (it is not on init.sh's
# python-free scaffold path).
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SELF_DIR/lib.sh"
P="${1:-$PWD}"
M="$(il_cfg_dir "$P")/manifest.json"
[ -f "$M" ] || { echo "drift: no manifest at $M (not a workbench project?)" >&2; exit 2; }
PLUGIN_VER="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$(dirname "${BASH_SOURCE[0]}")/../.claude-plugin/plugin.json" | head -1)"
MAN_VER="$(sed -n 's/.*"plugin_version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$M" | head -1)"

echo "workbench drift — project manifest v${MAN_VER:-?} vs plugin v${PLUGIN_VER:-?}"
[ "$MAN_VER" != "$PLUGIN_VER" ] && echo "  (plugin version advanced — managed templates may have changed)"
echo ""

command -v python3 >/dev/null 2>&1 || { echo "drift: python3 is required to classify drift but was not found on PATH." >&2; exit 3; }

python3 - "$M" "$P" <<'PY'
import json, sys, hashlib, os
man, proj = sys.argv[1], sys.argv[2]
d = json.load(open(man))
for f in d.get("files", []):
    path, mode, rec = f["path"], f["mode"], f.get("rendered_hash","")
    full = os.path.join(proj, path)
    if not os.path.exists(full):
        status = "missing"
    else:
        h = "sha256:" + hashlib.sha256(open(full,"rb").read()).hexdigest()
        status = "ok" if h == rec else "edited"
    print(f"  {path:34s} {mode:8s} {status}")
PY
