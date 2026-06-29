#!/usr/bin/env bash
# workbench upgrade classifier. It does not perform semantic merges; it gives
# Claude and the user a deterministic inventory before /workbench:upgrade acts.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SELF_DIR/lib.sh"
PLUGIN_ROOT="$(cd "$SELF_DIR/.." && pwd)"
TARGET="$PWD"
MODE="dry-run"

need_arg() { [ "$#" -ge 2 ] || { echo "upgrade.sh: $1 requires a value" >&2; exit 64; }; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --target) need_arg "$@"; TARGET="$2"; shift 2 ;;
    --dry-run) MODE="dry-run"; shift ;;
    --apply-managed) MODE="apply-managed"; shift ;;
    *) echo "upgrade.sh: unknown arg '$1'" >&2; exit 64 ;;
  esac
done

M="$(il_cfg_dir "$TARGET")/manifest.json"
[ -f "$M" ] || { echo "upgrade: no manifest at $M (not a workbench project?)" >&2; exit 2; }
# python3 parses the manifest ledger; fail cleanly if it's missing (matches scripts/drift.sh).
command -v python3 >/dev/null 2>&1 || { echo "upgrade: python3 is required to classify managed-file drift but was not found on PATH." >&2; exit 3; }

python3 - "$PLUGIN_ROOT" "$TARGET" "$M" "$MODE" <<'PY'
import hashlib
import json
import os
import sys

plugin_root, target, manifest_path, mode = sys.argv[1:5]
manifest = json.load(open(manifest_path))

plugin_json = os.path.join(plugin_root, ".claude-plugin", "plugin.json")
plugin_version = json.load(open(plugin_json)).get("version", "?")
manifest_version = manifest.get("plugin_version") or manifest.get("plugin", {}).get("version") or "?"

print(f"workbench upgrade {mode} -- project manifest v{manifest_version} vs plugin v{plugin_version}")
if manifest_version != plugin_version:
    print("  plugin-version-changed")
print("")

def sha(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return "sha256:" + h.hexdigest()

def template_hash(entry):
    template = entry.get("template") or ""
    full = os.path.join(plugin_root, "templates", template)
    return sha(full) if template and os.path.exists(full) else None

for entry in manifest.get("files", []):
    rel = entry["path"]
    mode_name = entry.get("mode", "?")
    full = os.path.join(target, rel)
    recorded = entry.get("rendered_hash") or ""
    preexisting = entry.get("preexisting") is True

    if not os.path.exists(full):
        status = "missing"
    else:
        current = sha(full)
        if current != recorded:
            status = "edited"
        elif preexisting:
            status = "preexisting"
        else:
            current_template_hash = template_hash(entry)
            recorded_template_hash = entry.get("template_hash")
            if current_template_hash and recorded_template_hash and current_template_hash != recorded_template_hash:
                status = "template-changed"
            else:
                status = "ok"

    print(f"  {rel:44s} {mode_name:8s} {status}")
PY
