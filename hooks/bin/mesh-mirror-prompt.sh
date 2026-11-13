#!/usr/bin/env bash
# Mirror what the operator types in this terminal into the command center, as
# a message from ui:operator to THIS session's own actor — so the dashboard
# shows the whole operator<->session conversation.
#
# OFF by default: a typed prompt is private until you opt in, per session with
# `/workbench:mesh mirror on` or for every session with WORKBENCH_MESH_MIRROR=on
# (WORKBENCH_MESH_MIRROR=off always wins). When on:
#   - only prompts a person typed are mirrored — never task notifications,
#     hook feedback or other injected turns, and never a headless lane's prompt;
#   - secret-shaped strings are redacted first (scripts/mesh-redact.sh);
#   - the event is tagged payload.mirror, so it is never delivered back to the
#     session as an inbound message.
# Fire-and-forget: never blocks or fails the prompt, prints nothing.
set -uo pipefail

[ "${WORKBENCH_MESH_MIRROR:-}" = "off" ] && exit 0
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT="${CLAUDE_PROJECT_DIR:-$PWD}"
MESH_DIR="$PROJECT/.workbench/mesh"
# only mirror when this project actually has a mesh
[ -f "$MESH_DIR/server.json" ] || exit 0
# shellcheck source=scripts/mesh-identity.sh
. "$SELF_DIR/../../scripts/mesh-identity.sh" 2>/dev/null || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

input="$(cat)"
sid="$(wb_mesh_session_id "$(printf '%s' "$input" | tr -d '\n' | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)")"
if [ "${WORKBENCH_MESH_MIRROR:-}" != "on" ]; then
  [ -n "$sid" ] && [ -f "$MESH_DIR/sessions/$sid.mirror" ] || exit 0
fi

ACTOR="$(wb_mesh_actor)"
# A headless lane's prompt came from a script, not from the operator.
case "$ACTOR" in session:*) ;; *) exit 0 ;; esac

prompt="$(printf '%s' "$input" | python3 -I -c '
import json, re, sys
try:
    p = json.load(sys.stdin).get("prompt", "")
except Exception:
    p = ""
if not isinstance(p, str):
    p = ""
p = p.strip()
# Injected turns arrive through the same hook as typed prompts: task
# notifications, hook feedback and system reminders all open with a tag.
if re.match(r"<[A-Za-z][A-Za-z0-9_-]*[\s>/]", p) or p.startswith("[SYSTEM NOTIFICATION"):
    p = ""
p = " ".join(p.split())
print(p[:500] + ("…" if len(p) > 500 else ""))
' 2>/dev/null | bash "$SELF_DIR/../../scripts/mesh-redact.sh" 2>/dev/null)"
[ -n "$prompt" ] || exit 0

MESH_SH="$SELF_DIR/../../scripts/mesh.sh"
post() {
  CLAUDE_PROJECT_DIR="$PROJECT" WORKBENCH_MESH_MESSAGE_MIRROR=1 bash "$MESH_SH" message "$ACTOR" "$prompt" --as ui:operator >/dev/null 2>&1 || true
}
if [ "${WORKBENCH_MESH_HOOK_WAIT:-0}" = 1 ]; then
  post
else
  # background so the prompt is never delayed; the mesh post is best-effort
  ( post ) </dev/null >/dev/null 2>&1 &
  disown 2>/dev/null || true
fi
exit 0
