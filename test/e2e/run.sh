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

# ---- scenario 4: the bare /workbench front door reports status on a configured project
note "4) /workbench front door reports status (no setup) on a configured project"
D4="$(scaffold "E2E Four" crew)"
# the front door summarizes status in prose, so assert on ANY status signal (level,
# a lifecycle stage, the cap, or "configured") rather than one exact word — it must
# report status, NOT re-run setup.
out="$(cd "$D4" && drive "$D4" 'Run /workbench and show me the status it reports.')"
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

# NOTE — known coverage gap: SessionStart / PreCompact hooks do NOT fire (or their
# injected context is not surfaced) under `claude -p`, so this harness cannot assert
# hook behavior. Hooks are covered structurally by test/hooks.test.sh and behaviorally
# by the interactive smoke test in docs/getting-started.md (relaunch a real session and
# confirm the operating brief prints).

# ---- summary ----------------------------------------------------------------
note "----"
if [ "$fail" = 0 ]; then note "E2E PASS ($pass checks)"; else note "E2E FAILED ($pass passed)"; fi
exit "$fail"
