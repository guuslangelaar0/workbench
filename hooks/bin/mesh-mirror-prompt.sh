#!/usr/bin/env bash
# Mirror the operator's terminal prompts onto the mesh, addressed to this
# session's lead actor, so the command center shows the complete
# operator<->lead conversation — not just what happens on the dashboard.
# Fire-and-forget: never blocks or fails the prompt. Opt out with
# WORKBENCH_MESH_MIRROR=off.
set -uo pipefail

[ "${WORKBENCH_MESH_MIRROR:-on}" = "off" ] && exit 0

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT="${CLAUDE_PROJECT_DIR:-$PWD}"
# only mirror when this project actually has a mesh
[ -f "$PROJECT/.workbench/mesh/server.json" ] || exit 0

input="$(cat)"
prompt="$(printf '%s' "$input" | python3 -c '
import json, sys
try:
    p = json.load(sys.stdin).get("prompt", "")
except Exception:
    p = ""
p = " ".join(p.split())
print(p[:500] + ("…" if len(p) > 500 else ""))
' 2>/dev/null)"
[ -n "$prompt" ] || exit 0

ACTOR="${WORKBENCH_MESH_ACTOR:-session:lead}"
MESH_SH="$SELF_DIR/../../scripts/mesh.sh"
[ -x "$MESH_SH" ] || MESH_SH="$SELF_DIR/../../scripts/mesh.sh"

# background so the prompt is never delayed; the mesh post is best-effort
(
  CLAUDE_PROJECT_DIR="$PROJECT" bash "$MESH_SH" message "$ACTOR" "$prompt" --as ui:operator >/dev/null 2>&1 || true
) &
disown 2>/dev/null || true
exit 0
