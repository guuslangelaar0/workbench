#!/usr/bin/env bash
# Workbench plugin publishability gate. Validates the plugin manifests against what a
# Claude Code marketplace expects, and checks internal consistency, so a broken or
# inconsistent plugin can't be published. Run before tagging/releasing.
#   bash scripts/validate-plugin.sh        # validate this plugin
#   bash scripts/validate-plugin.sh DIR    # validate the plugin at DIR
# Exits 0 if publishable, non-zero with a list of problems otherwise.
# Dev tooling: uses python3 for robust JSON parsing (not on the scaffold path).
set -uo pipefail
ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
command -v python3 >/dev/null 2>&1 || { echo "validate-plugin: python3 required" >&2; exit 3; }

python3 - "$ROOT" <<'PY'
import json, os, sys, glob, subprocess
root = sys.argv[1]
problems = []
def err(m): problems.append(m)

def load(path):
    full = os.path.join(root, path)
    if not os.path.exists(full): err(f"missing {path}"); return None
    try:
        return json.load(open(full))
    except Exception as e:
        err(f"{path} is not valid JSON: {e}"); return None

pj = load(".claude-plugin/plugin.json")
mk = load(".claude-plugin/marketplace.json")

# plugin.json required fields
if pj is not None:
    for k in ("name", "version", "description"):
        if not pj.get(k): err(f"plugin.json missing required field: {k}")
    lic = pj.get("license", "")
    if not lic: err("plugin.json missing license")
    elif lic.lower() in ("proprietary", "unlicensed"):
        err(f"plugin.json license is '{lic}' — set a real OSI license for marketplace distribution")
    # license should match a LICENSE file if one exists
    lf = os.path.join(root, "LICENSE")
    if os.path.exists(lf):
        body = open(lf).read().lower()
        if lic.lower() == "mit" and "mit license" not in body:
            err("plugin.json says MIT but LICENSE file is not an MIT license")
    else:
        err("no LICENSE file at repo root")
    hp = pj.get("homepage", "")
    if hp and "beebeeb" in hp:
        err(f"plugin.json homepage looks stale (points at beebeeb): {hp}")

# marketplace.json structure
plugin_entry = None
if mk is not None:
    if not mk.get("name"): err("marketplace.json missing name")
    if not mk.get("owner"): err("marketplace.json missing owner")
    plugins = mk.get("plugins") or []
    if not plugins: err("marketplace.json has no plugins[]")
    for p in plugins:
        if not p.get("name"): err("a marketplace plugin entry is missing name")
        if not p.get("source"): err(f"marketplace plugin '{p.get('name','?')}' missing source")
        if p.get("name") == (pj or {}).get("name"): plugin_entry = p

# consistency between the two manifests
if pj is not None and mk is not None:
    if plugin_entry is None:
        err(f"marketplace.json has no plugin matching plugin.json name '{pj.get('name')}'")
    else:
        pv, mv = pj.get("version"), plugin_entry.get("version")
        if mv and pv and mv != pv:
            err(f"version mismatch: plugin.json {pv} vs marketplace.json {mv}")

# the plugin must expose at least ONE surface (commands / skills / agents); a plugin
# with only commands is perfectly valid, so error only if ALL are absent.
surfaces = (glob.glob(os.path.join(root, "commands", "*.md"))
            + glob.glob(os.path.join(root, "skills", "*", "SKILL.md"))
            + glob.glob(os.path.join(root, "agents", "*.md")))
if not surfaces:
    err("plugin exposes nothing — found no commands/*.md, skills/*/SKILL.md, or agents/*.md")

mesh_command = os.path.join(root, "commands", "mesh.md")
mesh_script = os.path.join(root, "scripts", "mesh.sh")
mesh_launcher = os.path.join(root, "bin", "workbench-mesh")
mesh_bootstrap = os.path.join(root, "scripts", "mesh-bootstrap.sh")
mesh_skill = os.path.join(root, "skills", "mesh", "SKILL.md")
cargo_toml = os.path.join(root, "Cargo.toml")

if os.path.exists(mesh_command):
    try:
        command_body = open(mesh_command).read()
    except Exception as e:
        command_body = ""
        err(f"commands/mesh.md is not readable: {e}")
    if "scripts/mesh.sh" not in command_body:
        err("commands/mesh.md exists but does not reference scripts/mesh.sh")
    if not os.path.isfile(mesh_launcher):
        err("commands/mesh.md exists but bin/workbench-mesh is missing")
    elif not os.access(mesh_launcher, os.X_OK):
        err("commands/mesh.md exists but bin/workbench-mesh is not executable")
    if not os.path.isfile(mesh_script):
        err("commands/mesh.md exists but scripts/mesh.sh is missing")
    if not os.path.isfile(mesh_skill):
        err("commands/mesh.md exists but skills/mesh/SKILL.md is missing")
    if not os.path.isfile(cargo_toml):
        err("commands/mesh.md exists but Cargo.toml is missing")

if os.path.exists(mesh_script):
    result = subprocess.run(
        ["bash", "-n", mesh_script],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if result.returncode != 0:
        detail = (result.stderr or result.stdout).strip()
        err(f"scripts/mesh.sh fails bash -n: {detail}")

if os.path.exists(mesh_bootstrap):
    result = subprocess.run(
        ["bash", "-n", mesh_bootstrap],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if result.returncode != 0:
        detail = (result.stderr or result.stdout).strip()
        err(f"scripts/mesh-bootstrap.sh fails bash -n: {detail}")

if os.path.exists(mesh_launcher):
    packaged_bins = [
        path for path in glob.glob(os.path.join(root, "bin", "workbench-mesh.d", "*", "workbench-mesh"))
        if os.path.isfile(path) and os.access(path, os.X_OK)
    ]
    try:
        launcher_body = open(mesh_launcher).read()
    except Exception as e:
        launcher_body = ""
        err(f"bin/workbench-mesh is not readable: {e}")
    bootstrap = os.path.join(root, "scripts", "mesh-bootstrap.sh")
    bootstrap_support = (
        os.path.isfile(bootstrap)
        and os.access(bootstrap, os.X_OK)
        and "mesh-bootstrap.sh" in launcher_body
        and "CLAUDE_PLUGIN_DATA" in launcher_body
    )
    clear_error = (
        "packaged binary missing" in launcher_body
        and "cargo build -p workbench-mesh" in launcher_body
    )
    if not packaged_bins and not (bootstrap_support or clear_error):
        err("bin/workbench-mesh has no packaged target binaries and no bootstrap downloader/checksum support")

if problems:
    print("PLUGIN NOT PUBLISHABLE:")
    for p in problems: print(f"  - {p}")
    sys.exit(1)
name = pj.get("name"); ver = pj.get("version")
print(f"OK: {name} v{ver} is publishable (manifests valid + consistent, license {pj.get('license')}).")
PY
