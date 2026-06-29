#!/usr/bin/env bash
# workbench project uninstall. Removes only files and side effects the manifest
# says workbench owns, preserving user data and edited files by default.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SELF_DIR/lib.sh"
TARGET="$PWD"
APPLY=0
KEEP_DATA=0
FORCE=0

need_arg() { [ "$#" -ge 2 ] || { echo "uninstall.sh: $1 requires a value" >&2; exit 64; }; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --target) need_arg "$@"; TARGET="$2"; shift 2 ;;
    --dry-run) APPLY=0; shift ;;
    --apply) APPLY=1; shift ;;
    --keep-data) KEEP_DATA=1; shift ;;
    --force) FORCE=1; shift ;;
    *) echo "uninstall.sh: unknown arg '$1'" >&2; exit 64 ;;
  esac
done

M="$(il_cfg_dir "$TARGET")/manifest.json"
[ -f "$M" ] || { echo "uninstall: no manifest at $M; refusing destructive action" >&2; exit 2; }
# python3 parses the manifest ledger; guard before any destructive action so a missing
# interpreter fails cleanly (never mid-removal). Matches scripts/drift.sh's convention.
command -v python3 >/dev/null 2>&1 || { echo "uninstall: python3 is required to read the manifest ledger; aborting (no files touched)." >&2; exit 3; }

python3 - "$TARGET" "$M" "$APPLY" "$KEEP_DATA" "$FORCE" <<'PY'
import hashlib
import json
import os
import shutil
import sys

target, manifest_path = sys.argv[1], sys.argv[2]
apply = sys.argv[3] == "1"
keep_data = sys.argv[4] == "1"
force = sys.argv[5] == "1"
manifest = json.load(open(manifest_path))

def sha(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return "sha256:" + h.hexdigest()

remove = []
preserve = []
confirm = []

for entry in manifest.get("files", []):
    rel = entry["path"]
    full = os.path.join(target, rel)
    mode = entry.get("mode")
    action = entry.get("action")
    preexisting = entry.get("preexisting") is True
    recorded = entry.get("rendered_hash")

    if not os.path.exists(full):
        continue
    if mode != "managed":
        preserve.append((rel, mode or "unknown"))
        continue
    if preexisting or action == "preserved":
        preserve.append((rel, "preexisting"))
        continue

    unchanged = recorded and sha(full) == recorded
    if unchanged or force:
        remove.append(rel)
    else:
        confirm.append((rel, "managed edited"))

print("workbench uninstall " + ("apply" if apply else "dry-run"))
print("")
if remove:
    print("Would remove:" if not apply else "Removed:")
    for rel in remove:
        print(f"  {rel}")
if preserve:
    print("")
    print("Would preserve:" if not apply else "Preserved:")
    for rel, reason in preserve:
        print(f"  {rel} ({reason})")
if confirm:
    print("")
    print("Needs confirmation:")
    for rel, reason in confirm:
        print(f"  {rel} ({reason})")

side = manifest.get("side_effects", {})
gitignore_blocks = side.get("gitignore_blocks", [])
git_hooks = side.get("git_hooks", [])
if gitignore_blocks or git_hooks:
    print("")
    print("Would edit:" if not apply else "Edited:")
    for b in gitignore_blocks:
        print(f"  {b.get('path','.gitignore')} (remove {b.get('marker','workbench block')})")
    for h in git_hooks:
        print(f"  {h.get('path','.git/hooks/pre-commit')} (remove {h.get('marker','workbench hook')})")

if not apply:
    sys.exit(0)

def remove_gitignore_block(block):
    path = os.path.join(target, block.get("path", ".gitignore"))
    if not os.path.exists(path):
        return
    marker = block.get("marker", "workbench coordination runtime state")
    lines_to_remove = set(block.get("lines", []))
    out = []
    for line in open(path).read().splitlines():
        stripped = line.strip()
        if marker in line:
            continue
        if stripped in lines_to_remove:
            continue
        out.append(line)
    with open(path, "w") as f:
        f.write("\n".join(out).rstrip() + ("\n" if out else ""))

def remove_hook_block(hook):
    path = os.path.join(target, hook.get("path", ".git/hooks/pre-commit"))
    if not os.path.exists(path):
        return
    marker = hook.get("marker", "wb-coord commit guard (B)")
    start = f"# >>> {marker} >>>"
    end = f"# <<< {marker} <<<"
    out = []
    skipping = False
    for line in open(path).read().splitlines():
        if line.strip() == start:
            skipping = True
            continue
        if skipping and line.strip() == end:
            skipping = False
            continue
        if not skipping:
            out.append(line)
    with open(path, "w") as f:
        f.write("\n".join(out).rstrip() + ("\n" if out else ""))

for hook in git_hooks:
    remove_hook_block(hook)
for block in gitignore_blocks:
    remove_gitignore_block(block)

for rel in remove:
    full = os.path.join(target, rel)
    if os.path.isdir(full):
        shutil.rmtree(full)
    else:
        try:
            os.remove(full)
        except FileNotFoundError:
            pass

# Data is preserved by default. The flag is explicit documentation of intent for
# callers and future destructive modes.
if keep_data:
    pass
PY
