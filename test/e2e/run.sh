#!/usr/bin/env bash
# workbench end-to-end ("live plugin") tests.
#
# Unlike the suites in test/all.sh — which exercise the shell scripts directly and
# run free + offline — these load the ACTUAL plugin into a headless Claude Code
# session (`claude -p --plugin-dir`) and assert on what the model+commands+hooks do
# to the filesystem. This is the only layer that proves the plugin's markdown
# command/skill/hook surface works when a real model drives it.
#
# These cost tokens and need an authenticated `claude` CLI, so they are GATED:
#   WB_E2E=1 bash test/e2e/run.sh
# Without WB_E2E=1 (or without `claude` on PATH) the harness prints SKIP and exits 0,
# so it is safe to chain after test/all.sh in CI without breaking offline runs.
#
# Options (env):
#   WB_E2E=1            enable the suite (required)
#   WB_E2E_TIMEOUT=240  per-scenario timeout in seconds (default 240)
#   WB_E2E_MODEL=...    pass a specific model to `claude --model` (optional)
set -uo pipefail

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"   # workbench/ (test/e2e/ -> ../..)
INIT="$PLUGIN_ROOT/scripts/init.sh"
TIMEOUT="${WB_E2E_TIMEOUT:-240}"
fail=0
pass=0

note() { printf '%s\n' "$*"; }
ok()   { printf '  ok: %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  FAIL: %s\n' "$1" >&2; fail=1; }

# ---- gating -----------------------------------------------------------------
if [ "${WB_E2E:-0}" != 1 ]; then
  note "SKIP: live-plugin e2e tests are gated. Run with: WB_E2E=1 bash test/e2e/run.sh"
  exit 0
fi
if ! command -v claude >/dev/null 2>&1; then
  note "SKIP: 'claude' CLI not found on PATH — cannot run live-plugin e2e tests."
  exit 0
fi

# sanity: PLUGIN_ROOT must actually be a plugin, or --plugin-dir silently no-ops
# and every scenario fails with the misleading "command not found" fallback.
if [ ! -f "$PLUGIN_ROOT/.claude-plugin/plugin.json" ]; then
  note "ERROR: $PLUGIN_ROOT is not a plugin root (no .claude-plugin/plugin.json)."
  exit 2
fi

note "workbench live-plugin e2e — plugin: $PLUGIN_ROOT (timeout ${TIMEOUT}s/scenario)"
MODEL_ARG=(); [ -n "${WB_E2E_MODEL:-}" ] && MODEL_ARG=(--model "$WB_E2E_MODEL")

# ---- helpers ----------------------------------------------------------------
# scaffold a fresh scratch project (model-free) and echo its path
scaffold() { # <name> <level>
  local d; d="$(mktemp -d)"
  ( cd "$d" && git init -q )
  bash "$INIT" --name "$1" --level "$2" --target "$d" >/dev/null 2>&1
  printf '%s' "$d"
}

# drive a headless claude session with the plugin loaded, scoped to <dir>
drive() { # <dir> <prompt>  -> prints model output; returns claude's exit code
  timeout "$TIMEOUT" claude -p "$2" \
    --plugin-dir "$PLUGIN_ROOT" \
    --permission-mode bypassPermissions \
    --add-dir "$1" \
    "${MODEL_ARG[@]}" 2>&1
}

cleanup_mesh() { # <dir>
  local pid_file="$1/mesh.pid"
  if [ -s "$pid_file" ]; then
    kill "$(cat "$pid_file" 2>/dev/null)" >/dev/null 2>&1 || true
  fi
}

contains() { # <text> <extended-regex>
  printf '%s' "$1" | grep -qiE "$2"
}

mesh_server_is_local() { # <dir>
  python3 - "$1/.workbench/mesh/server.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as f:
    metadata = json.load(f)

if metadata.get("host") != "127.0.0.1":
    raise SystemExit("host is not local")
if not isinstance(metadata.get("port"), int) or metadata["port"] <= 0:
    raise SystemExit("port is not a positive integer")
PY
}

mesh_event_contains() { # <dir> <event-type> <payload-regex>
  local events="$1/.workbench/mesh/events.jsonl"
  [ -f "$events" ] || return 1
  python3 - "$events" "$2" "$3" <<'PY'
import json
import re
import sys

path, want_type, pattern = sys.argv[1:4]
evidence = re.compile(pattern, re.IGNORECASE)

with open(path, encoding="utf-8") as f:
    for raw in f:
        line = raw.rstrip("\n")
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue
        if event.get("type") == want_type and evidence.search(line):
            raise SystemExit(0)

raise SystemExit(1)
PY
}

# ---- scenario 1: the plugin loads and /workbench:task creates a task ---------
note "1) /workbench:task creates a backlog task"
D1="$(scaffold "E2E One" solo)"
out="$(cd "$D1" && drive "$D1" 'Run the /workbench:task command to create a task titled "live e2e alpha". Do it directly; do not ask me anything.')"
if ls "$D1"/.claude/tasks/backlog/*.md >/dev/null 2>&1; then
  ok "task file created in backlog/"
  grep -rqi "live e2e alpha" "$D1"/.claude/tasks/backlog/ && ok "task title written into the file" || bad "task title not found in file"
else
  bad "no task file created (model output: $(printf '%s' "$out" | tail -3 | tr '\n' ' '))"
fi
rm -rf "$D1"

# ---- scenario 2: /workbench:mc renders the dashboard for the project ---------
note "2) /workbench:mc renders the dashboard"
D2="$(scaffold "E2E Two" crew)"
bash "$PLUGIN_ROOT/scripts/task-new.sh" --title "Seeded Task" --target "$D2" >/dev/null 2>&1
out="$(cd "$D2" && drive "$D2" 'Run /workbench:mc with the --no-prod --no-build flags and show me the dashboard it prints.')"
printf '%s' "$out" | grep -q "E2E Two" && ok "dashboard names the project" || bad "dashboard did not name the project"
printf '%s' "$out" | grep -qi "backlog" && ok "dashboard shows the lifecycle stages" || bad "dashboard did not show lifecycle stages"
rm -rf "$D2"

# ---- scenario 3: /workbench:level reports the configured level ---------------
note "3) /workbench:level reports the level + dials"
D3="$(scaffold "E2E Three" fleet)"
out="$(cd "$D3" && drive "$D3" 'Run /workbench:level status and tell me the current level and dials.')"
printf '%s' "$out" | grep -qi "fleet" && ok "reports the configured level (fleet)" || bad "did not report level fleet"
rm -rf "$D3"

# ---- scenario 4: the /workbench:workbench front door reports status on a configured project
note "4) /workbench:workbench front door reports status (no setup) on a configured project"
D4="$(scaffold "E2E Four" crew)"
# the front door summarizes status in prose, so assert on ANY status signal (level,
# a lifecycle stage, the cap, or "configured") rather than one exact word — it must
# report status, NOT re-run setup.
out="$(cd "$D4" && drive "$D4" 'Run /workbench:workbench and show me the status it reports.')"
printf '%s' "$out" | grep -qiE 'crew|configured|in-review|backlog|staged|cap|level' \
  && ok "front door reports status on a configured project" \
  || bad "front door did not report status"
rm -rf "$D4"

# ---- scenario 5: /workbench:epic creates an epic (crew has the .claude/epics/ dir)
note "5) /workbench:epic creates an epic"
D5="$(scaffold "E2E Five" crew)"
out="$(cd "$D5" && drive "$D5" 'Run the /workbench:epic command to create an epic titled "live e2e backbone". Do it directly; do not ask me anything.')"
if ls "$D5"/.claude/epics/*.md >/dev/null 2>&1; then
  ok "epic file created in .claude/epics/"
  grep -rqi "live e2e backbone" "$D5"/.claude/epics/ && ok "epic title written into the file" || bad "epic title not found in file"
else
  bad "no epic file created (model output: $(printf '%s' "$out" | tail -3 | tr '\n' ' '))"
fi
rm -rf "$D5"

# ---- scenario 6: /workbench:architecture view summarizes the C4 backbone ---------
# crew's architecture dial = containers, so init scaffolds context.md + containers.md;
# the command reads them and summarizes — assert on any C4 signal in the prose.
note "6) /workbench:architecture view reports the backbone"
D6="$(scaffold "E2E Six" crew)"
out="$(cd "$D6" && drive "$D6" 'Run /workbench:architecture view and tell me which architecture docs it finds.')"
printf '%s' "$out" | grep -qiE 'context|container|architecture' \
  && ok "architecture view surfaces the C4 docs" \
  || bad "architecture view did not surface the backbone (model output: $(printf '%s' "$out" | tail -3 | tr '\n' ' '))"
rm -rf "$D6"

# ---- scenario 7: /workbench:architecture drift runs the automated assembler ------
# Seed a filled container row + a graphify report, then drive the model through the
# drift subcommand. It must run arch-drift.sh and surface the aligned comparison
# (the assembler's output), not just re-read the docs.
note "7) /workbench:architecture drift aligns docs vs. extracted reality"
D7="$(scaffold "E2E Seven" crew)"
mkdir -p "$D7/graphify-out"
cat > "$D7/graphify-out/GRAPH_REPORT.md" <<'REP'
# Graph Report - e2e seven
## Summary
- 80 nodes · 150 edges · 4 communities detected
## God Nodes (most connected - your core abstractions)
1. `request()` - 44 edges
2. `passArray8ToWasm0()` - 22 edges
REP
printf '| request | API client | TS | api |\n' >> "$D7/.claude/architecture/containers.md"
out="$(cd "$D7" && drive "$D7" 'Run /workbench:architecture drift and show me the comparison it prints.')"
printf '%s' "$out" | grep -qiE 'abstraction|declared|god.?node|named in|drift|request' \
  && ok "drift surfaces the assembler's aligned comparison" \
  || bad "drift did not surface the comparison (model output: $(printf '%s' "$out" | tail -3 | tr '\n' ' '))"
rm -rf "$D7"

# ---- scenario 8: /workbench:doctor reports project health -------------------
note "8) /workbench:doctor reports project health"
D8="$(scaffold "E2E Eight" crew)"
out="$(cd "$D8" && drive "$D8" 'Run /workbench:doctor and show me the health report it prints.')"
printf '%s' "$out" | grep -qiE 'doctor|manifest|drift|hooks|tasks:' \
  && ok "doctor surfaces the health report" \
  || bad "doctor did not surface health report (model output: $(printf '%s' "$out" | tail -3 | tr '\n' ' '))"
rm -rf "$D8"

# ---- scenario 9: /workbench:uninstall dry-run previews, mutates nothing -------
note "9) /workbench:uninstall dry-run previews removals and preserves the project"
D9="$(scaffold "E2E Nine" crew)"
out="$(cd "$D9" && drive "$D9" 'Run /workbench:uninstall as a dry-run and show me what it would remove and preserve. Do NOT apply anything.')"
{ [ -f "$D9/CLAUDE.md" ] && [ -f "$D9/.workbench/manifest.json" ] && [ -f "$D9/scripts/coord/lib.sh" ]; } \
  && ok "dry-run left the project intact" \
  || bad "dry-run mutated the project"
printf '%s' "$out" | grep -qiE 'preserve|would remove|remove:|coord' \
  && ok "uninstall preview lists removals/preserves" \
  || bad "uninstall preview missing (model output: $(printf '%s' "$out" | tail -3 | tr '\n' ' '))"
rm -rf "$D9"

# ---- scenario 10: /workbench:self-test runs the plugin-source self-test -------
# --skip-suite keeps it within the per-scenario timeout (the full suite runs in all.sh).
note "10) /workbench:self-test runs the plugin-source self-test"
D10="$(scaffold "E2E Ten" solo)"
out="$(cd "$D10" && drive "$D10" 'Run /workbench:self-test with the --skip-suite flag and tell me whether the checks passed.')"
printf '%s' "$out" | grep -qiE 'self-test|ok json|ok shell|ok plugin|passed' \
  && ok "self-test reports its check results" \
  || bad "self-test did not report (model output: $(printf '%s' "$out" | tail -3 | tr '\n' ' '))"
rm -rf "$D10"

# ---- scenario 11: /workbench:mesh starts the local command center ------------
note "11) /workbench:mesh starts local command center and prints URL"
D11="$(scaffold "E2E Mesh Start" crew)"
out="$(cd "$D11" && drive "$D11" 'Run /workbench:mesh start --local --port 0 --pid-file mesh.pid > mesh.log 2>&1 & through the Workbench plugin slash-command surface so it stays in the background. Wait until .workbench/mesh/server.json exists, then run /workbench:mesh open and print the exact Command center URL. Do not bypass the slash-command surface. Do not expose LAN. Do not run mesh start in the foreground.')"
contains "$out" 'Command center' \
  && contains "$out" 'http://127\.0\.0\.1:[0-9]+' \
  && mesh_server_is_local "$D11" \
  && ok "mesh start reports local command center" \
  || bad "mesh start did not report local command center URL (model output: $(printf '%s' "$out" | tail -3 | tr '\n' ' '))"
cleanup_mesh "$D11"
rm -rf "$D11"

# ---- scenario 12: /workbench:mesh creates a worker invite -------------------
note "12) /workbench:mesh invite creates a worker invite"
D12="$(scaffold "E2E Mesh Invite" crew)"
out="$(cd "$D12" && drive "$D12" 'Run /workbench:mesh start --local --port 0 --pid-file mesh.pid > mesh.log 2>&1 & through the Workbench plugin slash-command surface so it stays in the background. Wait until .workbench/mesh/server.json exists. Then run /workbench:mesh invite --role worker --ttl-seconds 900 and paste the exact invite command output, including token:, role:, expires:, and max_uses:. Then run /workbench:mesh open and paste its exact Command center URL. Do not summarize instead of showing the token, role, expiry, host/IP, and port. Do not bypass the slash-command surface. Do not run mesh start in the foreground.')"
contains "$out" 'wb_invite_' \
  && contains "$out" 'role:[[:space:]]*worker' \
  && contains "$out" 'expires:' \
  && contains "$out" 'http://127\.0\.0\.1:[0-9]+' \
  && mesh_server_is_local "$D12" \
  && grep -q 'invite.created' "$D12/.workbench/mesh/audit.jsonl" \
  && ok "mesh invite reports secure connection details" \
  || bad "mesh invite missing token, role, expiry, or local connection details (model output: $(printf '%s' "$out" | tail -3 | tr '\n' ' '))"
cleanup_mesh "$D12"
rm -rf "$D12"

# ---- scenario 13: /workbench:mesh maps natural collaboration intent ---------
note "13) /workbench:mesh maps natural team intent to chat/status events"
D13="$(scaffold "E2E Mesh Natural" crew)"
out="$(cd "$D13" && drive "$D13" 'Use the Workbench mesh plugin slash-command surface for every mesh operation. First start local mesh in the background with local-only binding, port 0, and pid-file mesh.pid, redirecting output to mesh.log so the session returns; wait until .workbench/mesh/server.json exists. Then handle this team request in the natural Workbench mesh way: create a checkout lead room named lead:checkout, send that room the chat message "what are you touching?", and show who is connected. Choose the appropriate /workbench:mesh operations yourself from the plugin guidance and print the concrete results from the room setup, chat send, and team roster. Do not call scripts/mesh.sh directly. Do not run mesh start in the foreground. Do not expose LAN.')"
mesh_event_contains "$D13" 'room.created' 'lead:checkout' \
  && mesh_event_contains "$D13" 'message.sent' 'what are you touching' \
  && contains "$out" 'connected_actor_count:[[:space:]]*[0-9]+|session:lead' \
  && ok "mesh natural intent produces collaboration output" \
  || bad "mesh natural intent did not persist room and message events (model output: $(printf '%s' "$out" | tail -3 | tr '\n' ' '))"
cleanup_mesh "$D13"
rm -rf "$D13"

# NOTE — known coverage gap: SessionStart / PreCompact hooks do NOT fire (or their
# injected context is not surfaced) under `claude -p`, so this harness cannot assert
# hook behavior. Hooks are covered structurally by test/hooks.test.sh and behaviorally
# by the interactive smoke test in docs/getting-started.md (relaunch a real session and
# confirm the operating brief prints).

# ---- summary ----------------------------------------------------------------
note "----"
if [ "$fail" = 0 ]; then note "E2E PASS ($pass checks)"; else note "E2E FAILED ($pass passed)"; fi
exit "$fail"
