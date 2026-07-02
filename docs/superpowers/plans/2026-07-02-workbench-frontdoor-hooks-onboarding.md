# Workbench Front Door Hooks Onboarding Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `/workbench:workbench` the single onboarding front door, give users a recommended hook-enabled path with an explicit lower-benefit skip path, and make future sessions honor that project hook choice.

**Architecture:** Workbench plugin hooks are already shipped in `hooks/hooks.json`; onboarding should not duplicate Claude Code hook definitions. Instead, setup/init record a project-level hook preference in `.workbench/config.json`, a shared status script reports enabled/disabled/missing/stale, and every Workbench hook script no-ops when the project has disabled hooks. Command/skill/docs copy then makes `/workbench:workbench` the primary mental model while keeping `/workbench:setup` and `/workbench:init` as explicit lower-level entry points.

**Tech Stack:** Bash, POSIX shell helpers, Python 3 for non-hook JSON config editing, Claude Code plugin markdown commands/skills, shell tests.

## Global Constraints

- `/workbench:workbench` is the single command new users need to remember.
- Hook activation is recommended and user-approved, not silent.
- Skipping hooks keeps slash commands working but disables automatic SessionStart/UserPromptSubmit/Stop/Statusline behavior for that project.
- Do not write duplicate Claude Code hook definitions; plugin hooks continue to live in `hooks/hooks.json`.
- Hook scripts must remain fast, offline, and fail-open.
- Hook-path checks must not depend on `jq` or Python.
- `scripts/hooks-mode.sh` may use Python 3 because it is an onboarding/status command, not a hook.
- Do not bump plugin version during feature implementation; use `CHANGELOG.md` `[Unreleased]` only.

---

## File Structure

- `test/hooks-mode.test.sh` - new outcome tests for project hook preference status and mutation.
- `test/frontdoor.test.sh` - command/skill copy tests for front-door routing and hook-choice wording.
- `test/hooks.test.sh` - behavioral tests that disabled hooks do not inject context or write checkpoint artifacts.
- `test/all.sh` - includes the new `hooks-mode` test.
- `scripts/hooks-mode.sh` - project-level hook preference/status helper: `status|enable|disable --target DIR`.
- `scripts/lib.sh` - adds fast hook-path helper `il_hooks_enabled`.
- `scripts/init.sh` - adds `--hooks enabled|disabled`, writes the hook preference for fresh configs, and updates it when explicitly requested for existing configs.
- `templates/schemas/config.schema.json` - documents optional `workbench.hooks`.
- `hooks/bin/*.sh` - each Workbench hook script checks `il_hooks_enabled "$PROJECT"` before doing project work.
- `commands/workbench.md` - front-door state machine includes hook choice/status.
- `commands/setup.md` - identifies setup as part of the front-door onboarding flow.
- `commands/init.md` - identifies init as the low-level scaffolder and documents `--hooks`.
- `skills/setup/SKILL.md` - onboarding wizard asks the hook question and passes `--hooks`.
- `README.md`, `docs/getting-started.md`, `docs/configuration.md`, `CHANGELOG.md` - user-facing documentation and release note.

---

### Task 1: Specify The Front Door And Hook Preference Contract

**Files:**
- Create: `test/hooks-mode.test.sh`
- Modify: `test/frontdoor.test.sh`
- Modify: `test/hooks.test.sh`
- Modify: `test/all.sh`

**Interfaces:**
- Consumes: existing `chk()` shell-test pattern.
- Produces: failing tests for `scripts/hooks-mode.sh`, onboarding copy, and disabled hook behavior.

- [ ] **Step 1: Create `test/hooks-mode.test.sh`**

Create `test/hooks-mode.test.sh` with this content:

```bash
#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail=0
chk() { if eval "$2"; then echo "ok: $1"; else echo "FAIL: $1" >&2; fail=1; fi; }
VERSION="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$HERE/.claude-plugin/plugin.json" | head -1)"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

UNCONFIGURED="$TMP/unconfigured"
mkdir -p "$UNCONFIGURED"
out_unconfigured="$(bash "$HERE/scripts/hooks-mode.sh" status --target "$UNCONFIGURED" --plugin-root "$HERE" 2>/dev/null || true)"
chk "unconfigured reports unconfigured" "printf '%s' \"\$out_unconfigured\" | grep -q '^state=unconfigured$'"

ENABLED="$TMP/enabled"
mkdir -p "$ENABLED"
bash "$HERE/scripts/init.sh" --profile full --name "HooksEnabled" --mission "m" --target "$ENABLED" --hooks enabled >/dev/null 2>&1
out_enabled="$(bash "$HERE/scripts/hooks-mode.sh" status --target "$ENABLED" --plugin-root "$HERE")"
chk "fresh init records hooks enabled" "python3 - <<PY
import json
d=json.load(open('$ENABLED/.workbench/config.json'))
assert d['workbench']['hooks']['mode'] == 'enabled'
assert d['workbench']['hooks']['version'] == '$VERSION'
PY"
chk "enabled status is current" "printf '%s' \"\$out_enabled\" | grep -q '^state=enabled$'"

bash "$HERE/scripts/hooks-mode.sh" disable --target "$ENABLED" --plugin-root "$HERE" >/dev/null
out_disabled="$(bash "$HERE/scripts/hooks-mode.sh" status --target "$ENABLED" --plugin-root "$HERE")"
chk "disable records disabled choice" "python3 - <<PY
import json
d=json.load(open('$ENABLED/.workbench/config.json'))
assert d['workbench']['hooks']['mode'] == 'disabled'
assert d['workbench']['hooks']['version'] == '$VERSION'
PY"
chk "disabled status is disabled-by-choice" "printf '%s' \"\$out_disabled\" | grep -q '^state=disabled$'"

bash "$HERE/scripts/hooks-mode.sh" enable --target "$ENABLED" --plugin-root "$HERE" >/dev/null
out_reenabled="$(bash "$HERE/scripts/hooks-mode.sh" status --target "$ENABLED" --plugin-root "$HERE")"
chk "enable records enabled choice" "python3 - <<PY
import json
d=json.load(open('$ENABLED/.workbench/config.json'))
assert d['workbench']['hooks']['mode'] == 'enabled'
assert d['workbench']['hooks']['version'] == '$VERSION'
PY"
chk "reenabled status is enabled" "printf '%s' \"\$out_reenabled\" | grep -q '^state=enabled$'"

SKIPPED="$TMP/skipped"
mkdir -p "$SKIPPED"
bash "$HERE/scripts/init.sh" --profile full --name "HooksSkipped" --mission "m" --target "$SKIPPED" --hooks disabled >/dev/null 2>&1
out_skipped="$(bash "$HERE/scripts/hooks-mode.sh" status --target "$SKIPPED" --plugin-root "$HERE")"
chk "init can record hooks disabled" "printf '%s' \"\$out_skipped\" | grep -q '^state=disabled$'"

MISSING="$TMP/missing"
mkdir -p "$MISSING/.workbench"
cat > "$MISSING/.workbench/config.json" <<'JSON'
{
  "workbench": { "version": "0.0.1", "initialized_at": "x", "level": "solo" },
  "project": { "name": "MissingHooks", "kind": "existing" },
  "way_of_working": {
    "models": "recommended",
    "verification": "recommended",
    "review": "recommended",
    "parallelism": "recommended",
    "enforcement": "warn-default",
    "continuity": "recommended",
    "graphify": "off",
    "codex": "off",
    "remote": "off",
    "inception_depth": "recommended"
  },
  "lifecycle": { "in_review_cap": 10 }
}
JSON
out_missing="$(bash "$HERE/scripts/hooks-mode.sh" status --target "$MISSING" --plugin-root "$HERE")"
chk "missing hook preference is reported" "printf '%s' \"\$out_missing\" | grep -q '^state=missing$'"

STALE="$TMP/stale"
mkdir -p "$STALE"
bash "$HERE/scripts/init.sh" --profile full --name "HooksStale" --mission "m" --target "$STALE" --hooks enabled >/dev/null 2>&1
python3 - <<PY
import json
p='$STALE/.workbench/config.json'
d=json.load(open(p))
d['workbench']['hooks']['version']='0.0.0'
open(p,'w').write(json.dumps(d, indent=2) + '\\n')
PY
out_stale="$(bash "$HERE/scripts/hooks-mode.sh" status --target "$STALE" --plugin-root "$HERE")"
chk "stale hook preference is reported" "printf '%s' \"\$out_stale\" | grep -q '^state=stale$'"

MALFORMED="$TMP/malformed"
mkdir -p "$MALFORMED/.workbench"
printf '{ not json\n' > "$MALFORMED/.workbench/config.json"
bash "$HERE/scripts/hooks-mode.sh" enable --target "$MALFORMED" --plugin-root "$HERE" >/tmp/workbench-hooks-mode.err 2>&1
rc=$?
chk "malformed config refuses mutation" "[ \"$rc\" -ne 0 ] && grep -qi 'invalid config json' /tmp/workbench-hooks-mode.err"

[ "$fail" = 0 ] && echo "PASS: hooks-mode" || { echo "hooks-mode test failed"; exit 1; }
```

- [ ] **Step 2: Extend `test/frontdoor.test.sh`**

Append these checks before the final PASS line:

```bash
chk "front door names hook recommendation" "grep -qi 'hook' '$F' && grep -qi 'recommended' '$F'"
chk "front door describes skip hooks lower benefit" "grep -qi 'skip hooks\\|without hooks\\|lower benefit\\|less benefit' '$F'"
chk "setup command refers to front door" "grep -q '/workbench:workbench' '$HERE/commands/setup.md'"
chk "init command refers to front door" "grep -q '/workbench:workbench' '$HERE/commands/init.md'"
chk "setup skill asks hook choice" "grep -qi 'Install Workbench hooks' '$HERE/skills/setup/SKILL.md'"
chk "setup skill explains skip hooks" "grep -qi 'slash commands still work' '$HERE/skills/setup/SKILL.md'"
```

- [ ] **Step 3: Extend `test/hooks.test.sh` for disabled hook behavior**

Insert this block after the existing `precompact no-op elsewhere` check and before `rm -rf "$TMP" "$ND" /tmp/pc.$$`:

```bash
DIS="$(mktemp -d)"
bash "$HERE/scripts/init.sh" --profile full --name "HooksOff" --mission m --target "$DIS" --hooks disabled >/dev/null 2>&1
disabled_brief="$(CLAUDE_PROJECT_DIR="$DIS" CLAUDE_PLUGIN_ROOT="$HERE" bash "$HERE/hooks/bin/ground-session.sh" </dev/null 2>/dev/null || true)"
chk "disabled hooks suppress SessionStart brief" "[ -z \"\$disabled_brief\" ]"
printf '{"trigger":"manual","session_id":"s1"}' | CLAUDE_PROJECT_DIR="$DIS" CLAUDE_PLUGIN_ROOT="$HERE" bash "$HERE/hooks/bin/precompact-checkpoint.sh" >/dev/null 2>&1
chk "disabled hooks suppress precompact checkpoint" "! ls '$DIS/.workbench/checkpoints/'*.json >/dev/null 2>&1"
printf '{"hook_event_name":"UserPromptSubmit","session_id":"s","prompt":"Let'\''s grab the next feature from the backlog."}' \
  | CLAUDE_PROJECT_DIR="$DIS" CLAUDE_PLUGIN_ROOT="$HERE" bash "$HERE/hooks/bin/intent-router.sh" > "$DIS/disabled-intent.json"
chk "disabled hooks suppress intent router" "[ ! -s '$DIS/disabled-intent.json' ]"
rm -rf "$DIS"
```

- [ ] **Step 4: Add `hooks-mode` to `test/all.sh`**

Change the `for t in ...` list so `hooks-mode` runs immediately after `hooks`:

```bash
for t in skeleton levels templates soul coord continuity hooks hooks-mode skills setup init command full-scaffold upgrade uninstall doctor self-test codex task-ops lead-purpose park mesh-protocol mesh-auth mesh-service mesh-ops mesh-packaging mesh-command-center mesh-hooks mesh-plugin-outcome epics mc orchestration multilead inception remote remote-guard dogfood lifecycle frontdoor graduation detect-level marketplace architecture arch-drift verification-gate lane watchdog loop-policy suggest gate-integrity budget cross-model suggest-scan regression-gate deps value-audit metric score benchmark intents expectancy-gate knobs bench release-gate; do
```

- [ ] **Step 5: Run failing tests**

Run:

```bash
bash test/hooks-mode.test.sh
bash test/frontdoor.test.sh
bash test/hooks.test.sh
```

Expected now:

```text
hooks-mode test failed
frontdoor test failed
hooks test failed
```

Failures are expected because `scripts/hooks-mode.sh`, `--hooks`, hook guards, and updated copy do not exist yet.

- [ ] **Step 6: Commit failing tests**

```bash
git add test/hooks-mode.test.sh test/frontdoor.test.sh test/hooks.test.sh test/all.sh
git commit -m "test: specify workbench hook onboarding"
```

---

### Task 2: Add Project Hook Preference And Status Helper

**Files:**
- Create: `scripts/hooks-mode.sh`
- Modify: `scripts/init.sh`
- Modify: `templates/schemas/config.schema.json`

**Interfaces:**
- Produces: `scripts/hooks-mode.sh status|enable|disable --target DIR [--plugin-root DIR]`.
- Produces: `scripts/init.sh --hooks enabled|disabled`.
- Produces config shape: `workbench.hooks.mode`, `workbench.hooks.version`, `workbench.hooks.updated_at`.

- [ ] **Step 1: Create `scripts/hooks-mode.sh`**

Create `scripts/hooks-mode.sh` with this content:

```bash
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
    "updated_at": datetime.datetime.utcnow().replace(microsecond=0).isoformat() + "Z",
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
```

- [ ] **Step 2: Make `hooks-mode.sh` executable**

Run:

```bash
chmod +x scripts/hooks-mode.sh
```

Expected: no output.

- [ ] **Step 3: Add `--hooks` parsing to `scripts/init.sh`**

At the variable declaration near the top, replace:

```bash
NAME="" MISSION="" LAUNCH="" TARGET="$PWD" PROFILE="full" LEVEL="" LEVEL_EXPLICIT=0
```

with:

```bash
NAME="" MISSION="" LAUNCH="" TARGET="$PWD" PROFILE="full" LEVEL="" LEVEL_EXPLICIT=0 HOOKS_MODE="enabled" HOOKS_EXPLICIT=0
```

In the argument parser, add this case after `--level)`:

```bash
    --hooks)   need_arg "$@"; HOOKS_MODE="$2"; HOOKS_EXPLICIT=1; shift 2 ;;
```

After the profile validation line:

```bash
case "$PROFILE" in minimal|full) ;; *) echo "init.sh: --profile must be minimal|full" >&2; exit 64 ;; esac
```

add:

```bash
case "$HOOKS_MODE" in enabled|disabled) ;; *) echo "init.sh: --hooks must be enabled|disabled" >&2; exit 64 ;; esac
```

- [ ] **Step 4: Write the hook preference into fresh configs**

In the fresh config JSON in `scripts/init.sh`, replace:

```json
  "workbench": { "version": "$VERSION", "initialized_at": "$NOW", "level": "$LEVEL" },
```

with:

```json
  "workbench": {
    "version": "$VERSION",
    "initialized_at": "$NOW",
    "level": "$LEVEL",
    "hooks": { "mode": "$HOOKS_MODE", "version": "$VERSION", "updated_at": "$NOW" }
  },
```

- [ ] **Step 5: Allow explicit hook preference updates on existing configs**

After the existing config level-upsert block in `scripts/init.sh`, add:

```bash
if [ "$HOOKS_EXPLICIT" = 1 ]; then
  if [ "$HOOKS_MODE" = enabled ]; then
    bash "$SELF_DIR/hooks-mode.sh" enable --target "$TARGET" --plugin-root "$PLUGIN_ROOT" >/dev/null
  else
    bash "$SELF_DIR/hooks-mode.sh" disable --target "$TARGET" --plugin-root "$PLUGIN_ROOT" >/dev/null
  fi
fi
```

- [ ] **Step 6: Update `templates/schemas/config.schema.json`**

Inside `properties.workbench.properties`, after the `level` property, add a comma after `level` and then add:

```json
        "hooks": {
          "type": "object",
          "required": ["mode", "version", "updated_at"],
          "properties": {
            "mode": { "enum": ["enabled", "disabled"] },
            "version": { "type": "string" },
            "updated_at": { "type": "string" }
          },
          "additionalProperties": false
        }
```

Keep `hooks` optional so existing Workbench configs without this field remain readable and can be reported as `state=missing`.

- [ ] **Step 7: Run targeted tests**

Run:

```bash
bash test/hooks-mode.test.sh
bash test/init.test.sh
bash test/setup.test.sh
```

Expected:

```text
PASS: hooks-mode
PASS: init
PASS: setup
```

- [ ] **Step 8: Commit hook preference helper**

```bash
git add scripts/hooks-mode.sh scripts/init.sh templates/schemas/config.schema.json
git commit -m "feat: add workbench hook preference status"
```

---

### Task 3: Make Workbench Hooks Honor The Project Preference

**Files:**
- Modify: `scripts/lib.sh`
- Modify: `hooks/bin/coord-ping.sh`
- Modify: `hooks/bin/ground-session.sh`
- Modify: `hooks/bin/intent-router.sh`
- Modify: `hooks/bin/lead-purpose-nudge.sh`
- Modify: `hooks/bin/mesh-context.sh`
- Modify: `hooks/bin/mesh-statusline.sh`
- Modify: `hooks/bin/notify.sh`
- Modify: `hooks/bin/precompact-checkpoint.sh`
- Modify: `hooks/bin/remote-guard.sh`
- Modify: `hooks/bin/stopfailure-recover.sh`
- Modify: `hooks/bin/teammate-idle-guard.sh`
- Modify: `hooks/bin/usage-meter.sh`

**Interfaces:**
- Consumes: `.workbench/config.json` optional `workbench.hooks.mode`.
- Produces: `il_hooks_enabled PROJECT_ROOT`, returning success unless the configured project explicitly disabled hooks.

- [ ] **Step 1: Add `il_hooks_enabled` to `scripts/lib.sh`**

Append this function after `il_cfg_dir()`:

```bash
# True when Workbench hooks should run for this project. Missing hook preference
# is treated as enabled for backward compatibility with pre-hook-choice configs.
il_hooks_enabled() { # <project_root>
  local cfg="$1"
  cfg="$(il_cfg_dir "$cfg")/config.json"
  [ -f "$cfg" ] || return 1
  awk '
    /"hooks"[[:space:]]*:/ { in_hooks=1 }
    in_hooks && /"mode"[[:space:]]*:[[:space:]]*"disabled"/ { disabled=1 }
    in_hooks && /\}/ { in_hooks=0 }
    END { exit disabled ? 1 : 0 }
  ' "$cfg" 2>/dev/null
}
```

- [ ] **Step 2: Guard hooks that already source `scripts/lib.sh`**

In these files, after the config exists check, add `[ il_hooks_enabled "$P" ]` using the exact project variable in that file:

`hooks/bin/coord-ping.sh`

```bash
[ -f "$(il_cfg_dir "$P")/config.json" ] || exit 0
il_hooks_enabled "$P" || exit 0
```

`hooks/bin/ground-session.sh`

```bash
_cfg="$(il_cfg_dir "$P")/config.json"
[ -f "$_cfg" ] || exit 0
il_hooks_enabled "$P" || exit 0
```

`hooks/bin/notify.sh`

```bash
_cfg="$(il_cfg_dir "$P")/config.json"
[ -f "$_cfg" ] || exit 0
il_hooks_enabled "$P" || exit 0
```

`hooks/bin/precompact-checkpoint.sh`

```bash
_cfg_dir="$(il_cfg_dir "$P")"
[ -f "$_cfg_dir/config.json" ] || exit 0
il_hooks_enabled "$P" || exit 0
```

`hooks/bin/remote-guard.sh`

```bash
_cfg="$(il_cfg_dir "$P")/config.json"
[ -f "$_cfg" ] || exit 0
il_hooks_enabled "$P" || exit 0
```

- [ ] **Step 3: Source `scripts/lib.sh` and guard `intent-router.sh`**

Near the top of `hooks/bin/intent-router.sh`, replace:

```bash
PROJECT="${CLAUDE_PROJECT_DIR:-$PWD}"
input="$(cat)"
```

with:

```bash
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SELF_DIR/../../scripts/lib.sh" 2>/dev/null || exit 0

PROJECT="${CLAUDE_PROJECT_DIR:-$PWD}"
[ -f "$(il_cfg_dir "$PROJECT")/config.json" ] || exit 0
il_hooks_enabled "$PROJECT" || exit 0
input="$(cat)"
```

- [ ] **Step 4: Source `scripts/lib.sh` and guard `lead-purpose-nudge.sh`**

After `PROJECT="${CLAUDE_PROJECT_DIR:-$PWD}"`, add:

```bash
. "$PLUGIN_ROOT/scripts/lib.sh" 2>/dev/null || exit 0
[ -f "$(il_cfg_dir "$PROJECT")/config.json" ] || exit 0
il_hooks_enabled "$PROJECT" || exit 0
```

- [ ] **Step 5: Source `scripts/lib.sh` and guard mesh hooks**

In both `hooks/bin/mesh-context.sh` and `hooks/bin/mesh-statusline.sh`, after `PROJECT="${CLAUDE_PROJECT_DIR:-$PWD}"`, add:

```bash
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SELF_DIR/../../scripts/lib.sh" 2>/dev/null || exit 0
[ -f "$(il_cfg_dir "$PROJECT")/config.json" ] || exit 0
il_hooks_enabled "$PROJECT" || exit 0
```

In `mesh-statusline.sh`, this means unconfigured projects no longer print the generic `workbench` fallback, which matches the lower-surprise onboarding model.

- [ ] **Step 6: Guard recovery, idle, and usage hooks**

In `hooks/bin/stopfailure-recover.sh`, after `CFG` is resolved, add:

```bash
[ -f "$CFG/config.json" ] || exit 0
if command -v il_hooks_enabled >/dev/null 2>&1; then
  il_hooks_enabled "$P" || exit 0
fi
```

In `hooks/bin/teammate-idle-guard.sh`, after `PROJECT="${CLAUDE_PROJECT_DIR:-$PWD}"`, add:

```bash
. "$PLUGIN_ROOT/scripts/lib.sh" 2>/dev/null || exit 0
[ -f "$(il_cfg_dir "$PROJECT")/config.json" ] || exit 0
il_hooks_enabled "$PROJECT" || exit 0
```

In `hooks/bin/usage-meter.sh`, after `_cfg="$(il_cfg_dir "$P")"`, add:

```bash
[ -f "$_cfg/config.json" ] || exit 0
il_hooks_enabled "$P" || exit 0
```

Keep all guards fail-open: if helper sourcing fails, exit `0`.

- [ ] **Step 7: Run targeted hook tests**

Run:

```bash
bash test/hooks.test.sh
bash test/mesh-hooks.test.sh
bash test/remote.test.sh
bash test/watchdog.test.sh
bash test/budget.test.sh
```

Expected:

```text
PASS: hooks
PASS: mesh-hooks
PASS: remote
PASS: watchdog
PASS: budget
```

- [ ] **Step 8: Commit hook preference enforcement**

```bash
git add scripts/lib.sh hooks/bin/*.sh
git commit -m "feat: honor workbench hook preference"
```

---

### Task 4: Update Front Door, Setup, Init, And Docs

**Files:**
- Modify: `commands/workbench.md`
- Modify: `commands/setup.md`
- Modify: `commands/init.md`
- Modify: `skills/setup/SKILL.md`
- Modify: `README.md`
- Modify: `docs/getting-started.md`
- Modify: `docs/configuration.md`
- Modify: `CHANGELOG.md`

**Interfaces:**
- Consumes: `scripts/hooks-mode.sh status|enable|disable`.
- Produces: user-facing onboarding copy and release note.

- [ ] **Step 1: Update `commands/workbench.md`**

Replace the body after the frontmatter with this text:

```markdown
You are the workbench front door. Decide what to do based on project state:

- If `${CLAUDE_PROJECT_DIR}/.workbench/config.json` does NOT exist -> this project isn't configured yet. Run the `setup` skill, which acts as the **level-aware adoption wizard**: it will assess the existing repo and git signals, give positive feedback on what's already in place, infer the current maturity level, recommend a target level, ask whether to enable Workbench hooks (**recommended**), then scaffold via `init.sh --level <chosen> --hooks <enabled|disabled>`. The wizard is the right first step for any new or existing project.
- If it DOES exist -> show the current status: run `/workbench:mc` (the dashboard) if available, else summarize task counts from `.claude/tasks/` and the SESSION_STATE "Now" snapshot. Then run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/hooks-mode.sh" status --target "${CLAUDE_PROJECT_DIR}"` and report whether Workbench hooks are enabled, disabled by choice, missing, or stale.
- If hook status is `missing` or `stale`, recommend enabling/updating hooks with `bash "${CLAUDE_PLUGIN_ROOT}/scripts/hooks-mode.sh" enable --target "${CLAUDE_PROJECT_DIR}"`. Explain that hooks let new sessions re-ground from disk, route normal chat into Workbench actions, keep lead purpose visible, surface mesh/team context, and checkpoint before compaction.
- If hook status is `disabled`, say slash commands still work, but the always-on behavior is disabled by choice. Offer to enable hooks.
- Offer the natural next actions: `/workbench:boot` (verify + brief), `/workbench:loop` (run the teamlead loop), `/workbench:inception` (greenfield genesis), `/workbench:setup` (reconfigure).

This is also the auto-trigger: any `/workbench:*` command, when run in an unconfigured project, should defer to this front-door assessment and setup first.

> **Power-user note:** `/workbench:setup` and `/workbench:init` remain explicit entry points for users who want setup-only or low-level scaffolding, but `/workbench:workbench` is the front door to remember (type `/workbench` to filter the command menu to it). It does the right thing automatically.
```

- [ ] **Step 2: Update `commands/setup.md`**

Replace the body after the frontmatter with this text:

```markdown
This command is part of the `/workbench:workbench` onboarding flow. If you are not sure what you need, run `/workbench:workbench`; it will route here when setup or reconfiguration is the right next step.

Run the workbench setup wizard for this project. Use the `setup` skill: walk the configuration axes one at a time as `AskUserQuestion` cards (Recommended first, with Better/Leaner + cost notes), ask whether to enable Workbench hooks (Recommended) or skip them (less benefit; slash commands still work), write `.workbench/config.json`, then scaffold via `init.sh --hooks <enabled|disabled>`.

If `.workbench/config.json` already exists, confirm whether the user wants to reconfigure. Re-running is safe: `init.sh` only writes files that are missing and never overwrites an existing CLAUDE.md/AGENTS.md/SOUL.md/coord script. Use `/workbench:upgrade` to reconcile existing files against current templates.
```

- [ ] **Step 3: Update `commands/init.md`**

In the frontmatter `argument-hint`, replace:

```yaml
argument-hint: "[--name <name>] [--mission <m>] [--launch <date>] [--level solo|pair|crew|fleet] [--profile minimal|full]"
```

with:

```yaml
argument-hint: "[--name <name>] [--mission <m>] [--launch <date>] [--level solo|pair|crew|fleet] [--profile minimal|full] [--hooks enabled|disabled]"
```

Replace the opening paragraph with:

```markdown
`/workbench:init` is the low-level scaffolding command. Most users should start with `/workbench:workbench` so Workbench can assess the repo, recommend a level, ask the hook question, and guide setup. Use this command directly only when you already know the scaffold options you want.
```

In step 3, replace the command example with:

```markdown
   `bash "${CLAUDE_PLUGIN_ROOT}/scripts/init.sh" --name "<name>" --level "<level>" [--profile minimal|full] [--mission "<m>"] [--launch "<date>"] [--hooks enabled|disabled] --target "${CLAUDE_PROJECT_DIR}"`
```

In step 4, replace the last sentence with:

```markdown
4. After it completes, summarize what was created and the hook mode. If hooks are disabled, say slash commands still work but new sessions will not automatically re-ground, route natural Workbench intents, surface lead purpose, or checkpoint before compaction. If `init.sh` reports any **preserved** files, pass that along and point the user at `/workbench:upgrade` to reconcile them.
```

- [ ] **Step 4: Update `skills/setup/SKILL.md`**

After Step 0b, add this new section:

```markdown
## Step 0c: Ask the Workbench hooks question

Ask:

```text
Install Workbench hooks? Recommended.
```

Options:

- **Yes, recommended** — new Claude sessions re-ground from disk, normal chat routes into Workbench actions, lead purpose stays visible, tangents can be parked, mesh/team context is surfaced, and compaction checkpoints preserve continuity.
- **No, skip hooks** — slash commands still work, but Claude will not automatically re-ground or route normal chat through Workbench in future sessions.

Record the answer as `--hooks enabled` or `--hooks disabled` when calling `init.sh`.
```

In Flow step 5, replace the scaffold command with:

```markdown
5. **Scaffold**: run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/init.sh" --name "<name>" --mission "<mission>" --launch "<launch>" --level "<chosen-level>" --profile full --hooks "<enabled-or-disabled>" --target "${CLAUDE_PROJECT_DIR}"`. The `--level` flag uses the level chosen in Step 0b (solo/pair/crew/fleet). The `--hooks` flag uses the answer from Step 0c.
```

In Flow step 6, append:

```markdown
If hooks are enabled, tell the user the next Claude session in this repo should automatically receive a Workbench operating brief. If hooks are disabled, tell the user that `/workbench:*` commands still work and hooks can be enabled later from `/workbench:workbench`.
```

- [ ] **Step 5: Update docs and changelog**

Add this paragraph to the README quick start after the `/workbench:workbench` example:

```markdown
During onboarding, Workbench asks whether to enable its hooks. The recommended answer is yes: hooks make future Claude sessions re-ground from disk, route normal chat into Workbench actions, surface lead purpose, and checkpoint before compaction. If you skip hooks, slash commands still work, but Workbench will not feel always-on in that repo.
```

Add this paragraph to `docs/getting-started.md` near the existing hook guidance:

```markdown
Workbench hooks are shipped by the plugin and controlled per project by `.workbench/config.json`. `/workbench:workbench` records whether hooks are enabled or disabled for the repo. Use `bash scripts/hooks-mode.sh status --target <repo>` from the plugin checkout to inspect the recorded state during development.
```

Add this row to the configuration table in `docs/configuration.md`:

```markdown
| `.workbench/config.json` `workbench.hooks` | Project-level hook preference. `enabled` gives the full always-on Workbench experience; `disabled` keeps slash commands available but makes plugin hooks no-op for that repo. |
```

Add this bullet under `CHANGELOG.md` `[Unreleased]`:

```markdown
- Workbench onboarding now makes `/workbench:workbench` the single front door, recommends project-level hooks for the always-on experience, supports an explicit skip-hooks path, and clarifies that `/workbench:setup` and `/workbench:init` are setup/scaffold entry points behind the front door.
```

- [ ] **Step 6: Run copy/docs tests**

Run:

```bash
bash test/frontdoor.test.sh
bash test/command.test.sh
bash scripts/validate-plugin.sh
```

Expected:

```text
PASS: frontdoor
PASS: command
```

`scripts/validate-plugin.sh` should exit `0`.

- [ ] **Step 7: Commit onboarding/docs changes**

```bash
git add commands/workbench.md commands/setup.md commands/init.md skills/setup/SKILL.md README.md docs/getting-started.md docs/configuration.md CHANGELOG.md
git commit -m "docs: clarify workbench front door onboarding"
```

---

### Task 5: Full Verification

**Files:**
- No new production files.

**Interfaces:**
- Consumes: all previous tasks.
- Produces: verified branch ready for review.

- [ ] **Step 1: Run focused verification**

Run:

```bash
bash test/hooks-mode.test.sh
bash test/hooks.test.sh
bash test/frontdoor.test.sh
bash test/init.test.sh
bash test/setup.test.sh
bash test/command.test.sh
bash test/mesh-hooks.test.sh
bash test/remote.test.sh
bash test/watchdog.test.sh
bash test/budget.test.sh
```

Expected each command prints `PASS: <name>`.

- [ ] **Step 2: Run full offline suite**

Run:

```bash
bash test/all.sh
```

Expected:

```text
ALL TESTS PASS
```

- [ ] **Step 3: Validate plugin and whitespace**

Run:

```bash
bash scripts/validate-plugin.sh
git diff --check
```

Expected: both commands exit `0`.

- [ ] **Step 4: Inspect git status**

Run:

```bash
git status --short --branch
```

Expected: branch has committed task changes and no untracked files except intentionally generated local evidence that should remain uncommitted.

- [ ] **Step 5: Commit any verification-only corrections**

If a verification correction was needed, inspect the exact changed files:

```bash
git status --short
```

Then stage only the files shown by `git status --short` that belong to the
verification correction and commit them:

```bash
git commit -m "fix: harden workbench hook onboarding"
```

Do not create this commit if verification passed without edits.

---

## Self-Review

- Spec coverage: `/workbench:workbench` primary entry, recommended hooks option, skip-hooks lower-benefit path, setup/init relationship, hook status, disabled behavior, and tests are all covered.
- Placeholder scan: no task uses placeholder markers or deferred implementation language.
- Type/interface consistency: `scripts/hooks-mode.sh` command names, `--hooks enabled|disabled`, `workbench.hooks.mode`, and test expectations match across tasks.
- Scope check: this plan only changes onboarding, hook preference/status, hook no-op behavior, docs, and tests; it does not change mesh service behavior or release versioning.
