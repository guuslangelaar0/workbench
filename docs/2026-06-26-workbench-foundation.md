# Workbench Foundation Implementation Plan (Rebrand R + Spec 1)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rebrand the `initlab` plugin to `workbench` and implement the maturity-ladder spine (levels, dials, lifecycle, graduation, loop-engineering, single front door) from the foundations spec.

**Architecture:** Evolve the existing `tools/initlab/` plugin (bash scripts + markdown skills/commands/agents + a `test/*.test.sh` harness) in place. Phase A is a mechanical rename gated by the existing 20 suites staying green. Phases B–E add level-aware behavior driven by a new `scripts/levels.sh` preset table that every other piece reads from `.workbench/config.json`.

**Tech Stack:** Bash (POSIX-ish, `set -euo pipefail`; scaffold path stays python-free + jq-free), Markdown skills/commands, the existing `chk()` bash test harness, Claude Code plugin manifest + hooks.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-06-26-workbench-foundations-design.md`. Every task implicitly inherits it.
- Levels: exactly `solo` / `pair` / `crew` / `fleet`. Stored in config as `workbench.level`.
- The four levels are **presets over dials**; a single dial may be overridden without changing level.
- Lifecycle directory sets per level (the `decisions/` dir is always present):
  - solo: `backlog in-development verified decisions`
  - pair: `backlog in-development in-review verified decisions`
  - crew: `backlog in-development in-review verified staged shipped decisions`
  - fleet: `backlog in-development in-review verified staged release-candidate shipped decisions`
- Graduation is **recommend-only** — detect + surface a decision, never auto-apply.
- Loop rule (verbatim): **bugs auto-file as tasks; new features/improvements are suggested, never auto-built.** Loop autonomy is inverse to level: solo=`auto-continue`, pair=`auto-continue`, crew=`suggest-wait`, fleet=`suggest-review`.
- One front door: `/workbench` (context-aware). `init`/`setup` are not separate user-facing verbs.
- Commits: scoped pathspecs (`git commit -- <paths>`), no `Co-Authored-By` line, author Guus. The `check-secrets` pre-commit hook is active.
- The scaffold path (`init.sh` + `lib.sh` it sources) stays python-free + jq-free; dev tooling (`drift.sh`, tests) may use python3.
- After every task: `bash tools/workbench/test/all.sh` must end with `ALL TESTS PASS`.

---

## File Structure

**Renamed (Phase A):** `tools/initlab/` → `tools/workbench/` (whole tree). `tools/.claude-plugin/marketplace.json` entry. Config convention `.initlab/` → `.workbench/`.

**New files:**
- `tools/workbench/scripts/levels.sh` — the level→dial preset table + lifecycle-dirs lookup (sourced by init.sh, level cmd, graduation, loop-policy).
- `tools/workbench/scripts/graduate.sh` — reads project signals, prints a level-up recommendation or nothing.
- `tools/workbench/scripts/loop-policy.sh` — prints the loop-autonomy mode for the configured level.
- `tools/workbench/skills/levels/SKILL.md` — explains the ladder + how `/workbench:level` works.
- `tools/workbench/commands/level.md` — `/workbench:level [status|up|down]`.
- `tools/workbench/test/{levels,lifecycle,graduation,loop-policy,frontdoor}.test.sh` — new suites.

**Modified:** `init.sh` (level-aware dirs + dials), `lib.sh` (config path + `bb-`→`wb-` rename), `drift.sh`, all `hooks/bin/*.sh`, `commands/workbench.md` (front door), `skills/setup/SKILL.md`, `skills/orchestration/SKILL.md` + `commands/loop.md` (loop rule), `templates/**`, `templates/schemas/config.schema.json`, `test/all.sh`.

---

## Phase A — Rebrand `initlab` → `workbench`

### Task A1: Rename the plugin tree, manifest, and marketplace entry

**Files:**
- Move: `tools/initlab/` → `tools/workbench/`
- Modify: `tools/workbench/.claude-plugin/plugin.json` (name), `tools/.claude-plugin/marketplace.json` (entry), `tools/workbench/test/all.sh` (no path refs, but verify)

**Interfaces:**
- Produces: plugin name `workbench`; `${CLAUDE_PLUGIN_ROOT}` now resolves under `…/workbench/…`.

- [ ] **Step 1: Move the tree with git**

```bash
cd /home/guus/code/beebeeb.io
git mv tools/initlab tools/workbench
```

- [ ] **Step 2: Update plugin.json name**

In `tools/workbench/.claude-plugin/plugin.json` change `"name": "initlab"` → `"name": "workbench"` (leave version `0.1.0`).

- [ ] **Step 3: Update the marketplace entry**

In `tools/.claude-plugin/marketplace.json`, the initlab plugin object: `"name": "initlab"` → `"workbench"`, `"source": "./initlab"` → `"./workbench"`, and update the `description` lead-in to say "workbench". Leave the `mission-control` entry untouched.

- [ ] **Step 4: Verify the suite still runs from the new path**

Run: `bash tools/workbench/test/all.sh`
Expected: `ALL TESTS PASS` (suites reference `$HERE` relatively, so they should pass unchanged).

- [ ] **Step 5: Commit**

```bash
git add -- tools/workbench tools/.claude-plugin/marketplace.json
git commit -m "workbench: rename plugin tree initlab->workbench + manifest + marketplace"
```

### Task A2: Rename the config-dir convention `.initlab/` → `.workbench/` (with read-compat)

**Files:**
- Modify: `tools/workbench/scripts/init.sh`, `scripts/drift.sh`, `scripts/lib.sh`, `templates/coord/lib.sh`, all `hooks/bin/*.sh`, `scripts/mc.sh`, `scripts/task-new.sh`, `scripts/task-move.sh`
- Test: `tools/workbench/test/init.test.sh`, `test/skeleton.test.sh`

**Interfaces:**
- Produces: scaffolds `.workbench/config.json` + `.workbench/manifest.json`; all scripts read `.workbench/` first, falling back to `.initlab/` if only the old dir exists (migration safety).

- [ ] **Step 1: Add a resolver to lib.sh**

In `tools/workbench/scripts/lib.sh` add near the top (after the shebang/guards):

```bash
# Resolve the workbench config dir for a project root: prefer .workbench/,
# fall back to a legacy .initlab/ so adopted projects keep working pre-migration.
il_cfg_dir() { # <project_root>
  if [ -d "$1/.workbench" ]; then printf '%s\n' "$1/.workbench"
  elif [ -d "$1/.initlab" ]; then printf '%s\n' "$1/.initlab"
  else printf '%s\n' "$1/.workbench"; fi
}
```

- [ ] **Step 2: Replace hard-coded `.initlab` writes with `.workbench`**

In `init.sh`: every `"$TARGET/.initlab/..."` literal that is *written* becomes `"$TARGET/.workbench/..."` (config.json, manifest.json, `mkdir -p`). In `drift.sh`, `mc.sh`, `task-new.sh`, `task-move.sh`, and `hooks/bin/{ground-session,precompact-checkpoint,coord-ping}.sh`: replace the `"$P/.initlab/config.json"` read with `"$(il_cfg_dir "$P")/config.json"` (source lib.sh where not already). The coord `templates/coord/lib.sh` `bb_workspace_root` marker check `.initlab/config.json` becomes a check for `.workbench/config.json` OR `.initlab/config.json`.

- [ ] **Step 3: Write the failing test**

Add to `tools/workbench/test/init.test.sh` before the final PASS line:

```bash
TMPW="$(mktemp -d)"
bash "$HERE/scripts/init.sh" --profile full --name "Wb" --mission m --target "$TMPW" >/dev/null 2>&1
chk "scaffolds .workbench/ not .initlab/" "[ -f '$TMPW/.workbench/config.json' ] && [ ! -d '$TMPW/.initlab' ]"
rm -rf "$TMPW"
```

- [ ] **Step 4: Run to verify it passes**

Run: `bash tools/workbench/test/init.test.sh`
Expected: `ok: scaffolds .workbench/ not .initlab/` and `PASS: init`.

- [ ] **Step 5: Run the full suite**

Run: `bash tools/workbench/test/all.sh`
Expected: `ALL TESTS PASS` (fix any suite that asserted `.initlab/`).

- [ ] **Step 6: Commit**

```bash
git add -- tools/workbench
git commit -m "workbench: config dir .initlab->.workbench with legacy read-compat"
```

### Task A3: Rename the user-facing namespace + coord scripts `bb-`→`wb-`

**Files:**
- Move: `tools/workbench/commands/initlab.md` → `commands/workbench.md`; `templates/coord/bb-coord` → `templates/coord/wb-coord`
- Modify: all `commands/*.md` + `skills/**/SKILL.md` + `agents/*.md` + `README.md` (replace `/initlab:` → `/workbench:`, `initlab` prose → `workbench`); `templates/coord/lib.sh` (`BB_`→`WB_` env var names, `bb_`→`wb_` fn names), `init.sh` (the coord copy loop + git-hook install reference to `bb-coord`), `templates/coord/{with-lock.sh,precommit-guard.sh,bb-worktree.sh,install-hooks.sh}` (internal `bb-coord`/`bb_` refs)
- Test: `tools/workbench/test/{coord,multilead,command}.test.sh`

**Interfaces:**
- Produces: front-door command `/workbench`; coordination CLI `wb-coord` with `WB_*` env vars; zero `/initlab:` references remain.

- [ ] **Step 1: Move the front-door command + coord script**

```bash
cd /home/guus/code/beebeeb.io/tools/workbench
git mv commands/initlab.md commands/workbench.md
git mv templates/coord/bb-coord templates/coord/wb-coord
```

- [ ] **Step 2: Bulk-replace namespace + prose references**

Replace `/initlab:` → `/workbench:` and the standalone product word `initlab` → `workbench` across `commands/`, `skills/`, `agents/`, `README.md`. In `templates/coord/*` and `init.sh` rename `bb-coord`→`wb-coord`, `BB_`→`WB_` (env vars: `BB_WORKSPACE_ROOT`→`WB_WORKSPACE_ROOT`, `BB_SESSION_TTL` etc.), `bb_`→`wb_` (function names). Update `hooks/bin/{ground-session,coord-ping}.sh` to invoke `wb-coord` and set `WB_WORKSPACE_ROOT`.

- [ ] **Step 3: Verify no stray references remain**

Run: `grep -rn "initlab\|/initlab:\|bb-coord\|BB_WORKSPACE_ROOT" tools/workbench --include='*.md' --include='*.sh' --include='*.json' | grep -v 'legacy\|\.initlab'`
Expected: no output (every hit is renamed; the only allowed `.initlab` mentions are the legacy read-compat comments from A2).

- [ ] **Step 4: Update tests that reference the old names**

In `test/coord.test.sh` and `test/multilead.test.sh` replace `bb-coord`→`wb-coord` and `BB_WORKSPACE_ROOT`→`WB_WORKSPACE_ROOT`; in `test/command.test.sh` replace front-door `initlab.md`→`workbench.md` and `/initlab:`→`/workbench:`.

- [ ] **Step 5: Run the full suite**

Run: `bash tools/workbench/test/all.sh`
Expected: `ALL TESTS PASS`.

- [ ] **Step 6: Commit**

```bash
git add -- tools/workbench
git commit -m "workbench: /workbench namespace + wb-coord/WB_ rename; front door = /workbench"
```

### Task A4: Migrate beebeeb.io's adopted `.initlab/` → `.workbench/`

**Files:**
- Move: `/home/guus/code/beebeeb.io/.initlab/` → `.workbench/`
- Modify: `.workbench/config.json` (`"initlab"` key → `"workbench"`), `.workbench/manifest.json` (no change needed)

**Interfaces:**
- Consumes: the renamed plugin (`tools/workbench`) from A1–A3.
- Produces: beebeeb is a `.workbench/`-managed project; `drift.sh` runs clean.

- [ ] **Step 1: Move the dir**

```bash
cd /home/guus/code/beebeeb.io
git mv .initlab .workbench
```

- [ ] **Step 2: Rename the top-level key in config.json**

In `.workbench/config.json` change the `"initlab": { ... }` object key to `"workbench": { ... }` (keep its fields).

- [ ] **Step 3: Verify drift is clean against the renamed plugin**

Run: `bash tools/workbench/scripts/drift.sh "$PWD"`
Expected: header prints, all 12 managed files `ok`.

- [ ] **Step 4: Commit**

```bash
git add -- .workbench
git commit -m "chore: migrate beebeeb adoption .initlab/ -> .workbench/ (workbench rebrand)"
```

---

## Phase B — Level + dial model

### Task B1: The level→dial preset table (`levels.sh`)

**Files:**
- Create: `tools/workbench/scripts/levels.sh`
- Test: `tools/workbench/test/levels.test.sh`, and wire into `test/all.sh`

**Interfaces:**
- Produces:
  - `wb_levels` → prints `solo pair crew fleet`
  - `wb_level_dials <level>` → prints `key=value` lines for all dials at that level
  - `wb_level_lifecycle <level>` → prints the space-separated stage-dir list for that level
  - `wb_level_index <level>` → prints `0|1|2|3` (for ordering/graduation comparisons), or empty + return 1 if unknown

- [ ] **Step 1: Write the failing test**

Create `tools/workbench/test/levels.test.sh`:

```bash
#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$HERE/scripts/levels.sh"
fail=0
chk() { if eval "$2"; then echo "ok: $1"; else echo "FAIL: $1" >&2; fail=1; fi; }

chk "lists four levels"            "[ \"\$(wb_levels)\" = 'solo pair crew fleet' ]"
chk "solo lifecycle has no in-review" "! wb_level_lifecycle solo | grep -qw in-review"
chk "pair lifecycle adds in-review"   "wb_level_lifecycle pair | grep -qw in-review"
chk "crew lifecycle adds staged"      "wb_level_lifecycle crew | grep -qw staged"
chk "fleet lifecycle adds release-candidate" "wb_level_lifecycle fleet | grep -qw release-candidate"
chk "decisions always present"        "wb_level_lifecycle solo | grep -qw decisions"
chk "solo loop_autonomy auto-continue" "wb_level_dials solo | grep -qx 'loop_autonomy=auto-continue'"
chk "crew loop_autonomy suggest-wait"  "wb_level_dials crew | grep -qx 'loop_autonomy=suggest-wait'"
chk "solo release push-to-main"        "wb_level_dials solo | grep -qx 'release=push-to-main'"
chk "fleet graphify federated"         "wb_level_dials fleet | grep -qx 'graphify=federated'"
chk "index orders levels"             "[ \"\$(wb_level_index fleet)\" -gt \"\$(wb_level_index solo)\" ]"
chk "unknown level returns 1"         "! wb_level_index bogus >/dev/null 2>&1"

[ "$fail" = 0 ] && echo "PASS: levels" || { echo "levels test failed"; exit 1; }
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tools/workbench/test/levels.test.sh`
Expected: FAIL (`levels.sh` not found / functions undefined).

- [ ] **Step 3: Implement `levels.sh`**

Create `tools/workbench/scripts/levels.sh`:

```bash
#!/usr/bin/env bash
# Workbench maturity-ladder preset table. The single source of truth for what
# each level (solo|pair|crew|fleet) presets across the dials. Pure bash, no deps.

wb_levels() { printf 'solo pair crew fleet\n'; }

wb_level_index() { # <level> -> 0..3 ; return 1 if unknown
  case "${1:-}" in
    solo) echo 0 ;; pair) echo 1 ;; crew) echo 2 ;; fleet) echo 3 ;;
    *) return 1 ;;
  esac
}

wb_level_lifecycle() { # <level> -> space-separated stage dirs
  case "${1:-}" in
    solo)  echo "backlog in-development verified decisions" ;;
    pair)  echo "backlog in-development in-review verified decisions" ;;
    crew)  echo "backlog in-development in-review verified staged shipped decisions" ;;
    fleet) echo "backlog in-development in-review verified staged release-candidate shipped decisions" ;;
    *) return 1 ;;
  esac
}

wb_level_dials() { # <level> -> key=value lines
  local L="${1:-}"; wb_level_index "$L" >/dev/null || return 1
  local team release decomp arch surfaces graphify loop
  case "$L" in
    solo)  team=solo;  release=push-to-main;     decomp=tasks;            arch=none;        surfaces=one;     graphify=off;       loop=auto-continue ;;
    pair)  team=pair;  release=feature-branch;   decomp=light-epics;      arch=context;     surfaces=two;     graphify=per-repo;  loop=auto-continue ;;
    crew)  team=crew;  release=tagged-releases;  decomp=epics;            arch=containers;  surfaces=several; graphify=workspace; loop=suggest-wait ;;
    fleet) team=fleet; release=release-trains;   decomp=themes-epics;     arch=components;  surfaces=many;    graphify=federated; loop=suggest-review ;;
  esac
  printf 'team=%s\nrelease=%s\ndecomposition=%s\narchitecture=%s\nsurfaces=%s\ngraphify=%s\nloop_autonomy=%s\n' \
    "$team" "$release" "$decomp" "$arch" "$surfaces" "$graphify" "$loop"
}
```

- [ ] **Step 4: Run to verify it passes + wire into the runner**

Run: `bash tools/workbench/test/levels.test.sh` → `PASS: levels`.
Add `levels` to the `for t in …` list in `test/all.sh` (after `skeleton`).
Run: `bash tools/workbench/test/all.sh` → `ALL TESTS PASS`.

- [ ] **Step 5: Commit**

```bash
git add -- tools/workbench/scripts/levels.sh tools/workbench/test/levels.test.sh tools/workbench/test/all.sh
git commit -m "workbench: levels.sh — level->dial preset table (the ladder spine)"
```

### Task B2: `init.sh` writes `level` + `dials` and creates level-appropriate stage dirs

**Files:**
- Modify: `tools/workbench/scripts/init.sh` (source levels.sh; accept `--level`; write level+dials; create dirs from `wb_level_lifecycle`), `templates/schemas/config.schema.json`
- Test: `tools/workbench/test/lifecycle.test.sh` (new), `test/init.test.sh`

**Interfaces:**
- Consumes: `levels.sh` (B1).
- Produces: `.workbench/config.json` with `workbench.level` + a `dials` object; stage dirs match the level.

- [ ] **Step 1: Write the failing test**

Create `tools/workbench/test/lifecycle.test.sh`:

```bash
#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail=0
chk() { if eval "$2"; then echo "ok: $1"; else echo "FAIL: $1" >&2; fail=1; fi; }

T1="$(mktemp -d)"; bash "$HERE/scripts/init.sh" --profile full --level solo  --name S --mission m --target "$T1" >/dev/null 2>&1
chk "solo: no in-review dir"   "[ ! -d '$T1/.claude/tasks/in-review' ]"
chk "solo: has verified dir"   "[ -d '$T1/.claude/tasks/verified' ]"
chk "solo: config level=solo"  "grep -q '\"level\": \"solo\"' '$T1/.workbench/config.json'"
chk "solo: dials present"      "grep -q '\"loop_autonomy\": \"auto-continue\"' '$T1/.workbench/config.json'"

T2="$(mktemp -d)"; bash "$HERE/scripts/init.sh" --profile full --level fleet --name F --mission m --target "$T2" >/dev/null 2>&1
chk "fleet: has release-candidate dir" "[ -d '$T2/.claude/tasks/release-candidate' ]"
chk "fleet: has staged dir"            "[ -d '$T2/.claude/tasks/staged' ]"
rm -rf "$T1" "$T2"
[ "$fail" = 0 ] && echo "PASS: lifecycle" || { echo "lifecycle test failed"; exit 1; }
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tools/workbench/test/lifecycle.test.sh`
Expected: FAIL (`--level` unknown arg / no `level` in config / wrong dirs).

- [ ] **Step 3: Implement in `init.sh`**

Source levels.sh after lib.sh: `. "$SELF_DIR/levels.sh"`. Add `--level) need_arg "$@"; LEVEL="$2"; shift 2 ;;` to the arg loop with default `LEVEL="${LEVEL:-fleet}"` (full profile default; `minimal` profile defaults `LEVEL=solo`). Validate with `wb_level_index "$LEVEL" >/dev/null || { echo "init.sh: --level must be solo|pair|crew|fleet" >&2; exit 64; }`. Replace the hard-coded `for d in backlog in-development in-review verified decisions` loop with `for d in $(wb_level_lifecycle "$LEVEL"); do mkdir -p "$TARGET/.claude/tasks/$d"; done`. In the config.json heredoc: change the top key object to `"workbench": { "version": "$VERSION", "initialized_at": "$NOW", "level": "$LEVEL" }`, and replace the `way_of_working` block with a `dials` block built from `wb_level_dials`:

```bash
DIALS_JSON="$(wb_level_dials "$LEVEL" | sed 's/^\([^=]*\)=\(.*\)$/    "\1": "\2",/' | sed '$ s/,$//')"
```
and emit `"dials": {\n$DIALS_JSON\n  },` in the heredoc. Set `lifecycle.states` from `wb_level_lifecycle "$LEVEL"` (drop `decisions`), and `deploy_gated` = true when the level is crew/fleet.

- [ ] **Step 4: Run both tests to verify they pass**

Run: `bash tools/workbench/test/lifecycle.test.sh` → `PASS: lifecycle`.
Run: `bash tools/workbench/test/init.test.sh` → `PASS: init` (update any assertion that expected the old `way_of_working` key).

- [ ] **Step 5: Update the schema + wire the new suite**

In `templates/schemas/config.schema.json` add `level` (enum solo/pair/crew/fleet) under `workbench`, add the `dials` object, keep `lifecycle`. Add `lifecycle` to `test/all.sh`.
Run: `bash tools/workbench/test/all.sh` → `ALL TESTS PASS`.

- [ ] **Step 6: Commit**

```bash
git add -- tools/workbench
git commit -m "workbench: init.sh level-aware — writes level+dials, level-appropriate stage dirs"
```

### Task B3: Context-aware `/workbench` front door + retire init/setup as separate verbs

**Files:**
- Modify: `tools/workbench/commands/workbench.md` (the front door), `skills/setup/SKILL.md` (becomes the level-aware adoption wizard invoked by the front door), `commands/init.md` + `commands/setup.md` (kept as thin power-user aliases that defer to the front-door behavior, with a note they're not the primary entry)
- Test: `tools/workbench/test/frontdoor.test.sh` (new) — asserts the command docs encode the context-aware contract

**Interfaces:**
- Consumes: the setup skill, `init.sh`.
- Produces: `/workbench` documented to (a) run the level-aware adoption wizard when `.workbench/config.json` is absent, (b) show status + next actions when present.

- [ ] **Step 1: Write the failing test**

Create `tools/workbench/test/frontdoor.test.sh`:

```bash
#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail=0
chk() { if eval "$2"; then echo "ok: $1"; else echo "FAIL: $1" >&2; fail=1; fi; }
F="$HERE/commands/workbench.md"
chk "front door command exists"        "[ -f '$F' ]"
chk "front door: unconfigured -> wizard" "grep -qi 'config.json' '$F' && grep -qi 'adoption\|wizard\|assess' '$F'"
chk "front door: configured -> status"   "grep -qi 'status\|next action' '$F'"
chk "front door: positive feedback"      "grep -qi 'positive' '$F'"
chk "setup skill assesses + recommends level" "grep -qi 'level' '$HERE/skills/setup/SKILL.md' && grep -qi 'assess\|positive' '$HERE/skills/setup/SKILL.md'"
[ "$fail" = 0 ] && echo "PASS: frontdoor" || { echo "frontdoor test failed"; exit 1; }
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tools/workbench/test/frontdoor.test.sh`
Expected: FAIL on the assessment/level/positive assertions.

- [ ] **Step 3: Rewrite `commands/workbench.md`**

Make it the single context-aware front door: detect `.workbench/config.json`; if absent → invoke the `setup` skill to run the **level-aware adoption wizard** (assess existing repo/git signals, give *positive feedback* on what's there, infer current level, recommend a target, scaffold via `init.sh --level <chosen>`); if present → show status (current level, task counts per stage, what the loop is doing, pending suggestions + decisions, open drift). Note that `/workbench:init` and `/workbench:setup` remain as explicit power-user aliases but `/workbench` is the one to remember.

- [ ] **Step 4: Update the setup skill**

In `skills/setup/SKILL.md` add an opening **assessment** step (read git history, branch model, tags, repo count, existing tasks/docs), a **positive-feedback** instruction ("name what's already good"), and **level inference + recommendation** (map signals → solo/pair/crew/fleet using `wb_level_index` ordering), then run `init.sh --level <recommended-or-chosen>`. Keep the per-axis dial-override questions as the override mechanism.

- [ ] **Step 5: Run tests**

Run: `bash tools/workbench/test/frontdoor.test.sh` → `PASS: frontdoor`.
Add `frontdoor` to `test/all.sh`. Run `bash tools/workbench/test/all.sh` → `ALL TESTS PASS`.

- [ ] **Step 6: Commit**

```bash
git add -- tools/workbench
git commit -m "workbench: single context-aware /workbench front door + level-aware adoption wizard"
```

### Task B4: `/workbench:level` command + `levels` skill (status / up / down)

**Files:**
- Create: `tools/workbench/commands/level.md`, `tools/workbench/skills/levels/SKILL.md`
- Test: `tools/workbench/test/levels.test.sh` (extend with a command-doc check)

**Interfaces:**
- Consumes: `levels.sh`, `graduate.sh` (Phase D, referenced).
- Produces: `/workbench:level` documented to print current level + dials (`status`), and to apply a level change (`up`/`down`/`<name>`) by re-running `init.sh --level <new>` (non-destructive) + re-stamping config, after showing exactly which dials change.

- [ ] **Step 1: Write the failing test (extend levels suite)**

Append to `tools/workbench/test/levels.test.sh` before the PASS line:

```bash
chk "level command exists"        "[ -f '$HERE/commands/level.md' ]"
chk "level command: status/up/down" "grep -qi 'status' '$HERE/commands/level.md' && grep -qi 'up' '$HERE/commands/level.md' && grep -qi 'down' '$HERE/commands/level.md'"
chk "level command: shows dial changes before applying" "grep -qi 'which dials\|dials change\|before applying\|confirm' '$HERE/commands/level.md'"
chk "levels skill exists"         "[ -f '$HERE/skills/levels/SKILL.md' ]"
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tools/workbench/test/levels.test.sh`
Expected: FAIL on the command/skill existence checks.

- [ ] **Step 3: Write `commands/level.md`**

Frontmatter (`description`, `allowed-tools: ["Bash","Read","AskUserQuestion"]`, `argument-hint: "[status|up|down|<level>]"`). Body: `status` → read `.workbench/config.json` level + dials and print them; `up`/`down` → compute neighbor via `wb_level_index`; `<level>` → that level. Before applying: print the diff of dials (`wb_level_dials <current>` vs `<new>`) and the lifecycle dirs that will be added, confirm, then run `init.sh --level <new> --target "${CLAUDE_PROJECT_DIR}"` (non-destructive: it only adds missing stage dirs and re-stamps level/dials; existing tasks are untouched) and report.

- [ ] **Step 4: Write `skills/levels/SKILL.md`**

Explain the ladder (Solo/Pair/Crew/Fleet = coordination surface), presets-over-dials, single-dial override, and that graduation is recommend-only (points at `graduate.sh`). Frontmatter `name: levels`, description per the convention.

- [ ] **Step 5: Run tests**

Run: `bash tools/workbench/test/levels.test.sh` → `PASS: levels`.
Run: `bash tools/workbench/test/all.sh` → `ALL TESTS PASS`.

- [ ] **Step 6: Commit**

```bash
git add -- tools/workbench/commands/level.md tools/workbench/skills/levels tools/workbench/test/levels.test.sh
git commit -m "workbench: /workbench:level (status/up/down) + levels skill"
```

---

## Phase C — Lifecycle transitions

### Task C1: `task-move.sh` knows the new stages + enforces the cap on the right dir

**Files:**
- Modify: `tools/workbench/scripts/task-move.sh`
- Test: `tools/workbench/test/lifecycle.test.sh` (extend)

**Interfaces:**
- Consumes: `levels.sh`, the level's stage dirs.
- Produces: `task-move.sh <id> <stage>` validates `<stage>` against the project's configured lifecycle (rejects `staged` in a solo project), moves the file, and keeps the `**Status:**` line in sync.

- [ ] **Step 1: Write the failing test**

Append to `lifecycle.test.sh`:

```bash
T3="$(mktemp -d)"; bash "$HERE/scripts/init.sh" --profile full --level crew --name C --mission m --target "$T3" >/dev/null 2>&1
bash "$HERE/scripts/task-new.sh" --target "$T3" --title "Ship me" >/dev/null 2>&1
id="$(ls "$T3/.claude/tasks/backlog" | head -1 | sed 's/-.*//')"
bash "$HERE/scripts/task-move.sh" --target "$T3" "$id" staged >/dev/null 2>&1
chk "crew: task moved to staged"  "ls '$T3/.claude/tasks/staged/' | grep -q "$id""
chk "crew: status line synced"    "grep -qi 'Status:.*staged' \"\$(ls '$T3/.claude/tasks/staged/'*.md | head -1)\""
T4="$(mktemp -d)"; bash "$HERE/scripts/init.sh" --profile full --level solo --name So --mission m --target "$T4" >/dev/null 2>&1
bash "$HERE/scripts/task-new.sh" --target "$T4" --title "x" >/dev/null 2>&1
sid="$(ls "$T4/.claude/tasks/backlog" | head -1 | sed 's/-.*//')"
chk "solo: staged is rejected" "! bash "$HERE/scripts/task-move.sh" --target "$T4" "$sid" staged >/dev/null 2>&1"
rm -rf "$T3" "$T4"
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tools/workbench/test/lifecycle.test.sh`
Expected: FAIL (task-move accepts any dir / no validation).

- [ ] **Step 3: Implement in `task-move.sh`**

Source `levels.sh` + `lib.sh`. Read the project level from `$(il_cfg_dir "$TARGET")/config.json` (sed for `"level"`). Compute the valid stage set `wb_level_lifecycle "$LEVEL"`. If the requested stage isn't in the set → `echo "task-move: '$stage' is not a stage at level '$LEVEL'" >&2; exit 64`. Otherwise `git mv` (or `mv`) the matching `*<id>*.md` to the new dir and rewrite its `**Status:**` line to the stage (insert one if missing, per the existing Plan-6 behavior).

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tools/workbench/test/lifecycle.test.sh` → `PASS: lifecycle`.
Run: `bash tools/workbench/test/task-ops.test.sh` → `PASS: task-ops` (adjust if it assumed the old fixed stage set).

- [ ] **Step 5: Run full suite + commit**

Run: `bash tools/workbench/test/all.sh` → `ALL TESTS PASS`.

```bash
git add -- tools/workbench
git commit -m "workbench: task-move validates stages against the project's level lifecycle"
```

---

## Phase D — Graduation engine (recommend-only)

### Task D1: `graduate.sh` — detect signals, print a recommendation or nothing

**Files:**
- Create: `tools/workbench/scripts/graduate.sh`
- Test: `tools/workbench/test/graduation.test.sh` (new)

**Interfaces:**
- Consumes: `levels.sh`, project `.git` + `.workbench/config.json`.
- Produces: `graduate.sh <project_root>` prints either nothing (no graduation warranted) or a single recommendation block naming the suggested next level + the specific signal(s) that triggered it. Exit 0 always (advisory).

- [ ] **Step 1: Write the failing test**

Create `tools/workbench/test/graduation.test.sh`:

```bash
#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail=0
chk() { if eval "$2"; then echo "ok: $1"; else echo "FAIL: $1" >&2; fail=1; fi; }

# A solo project that has acquired a git tag should be nudged toward pair/crew.
P="$(mktemp -d)"; ( cd "$P" && git init -q && git config user.email a@b.c && git config user.name A )
bash "$HERE/scripts/init.sh" --profile full --level solo --name G --mission m --target "$P" >/dev/null 2>&1
( cd "$P" && git add -A && git commit -qm init && git tag v0.1.0 )
out="$(bash "$HERE/scripts/graduate.sh" "$P" 2>/dev/null)"
chk "tag triggers a recommendation"  "printf '%s' \"\$out\" | grep -qi 'recommend\|consider'"
chk "recommendation names the signal" "printf '%s' \"\$out\" | grep -qi 'tag\|release'"
chk "advisory exit 0"                 "bash "$HERE/scripts/graduate.sh" "$P" >/dev/null 2>&1; [ \$? -eq 0 ]"

# A fresh solo project with nothing notable stays quiet.
Q="$(mktemp -d)"; ( cd "$Q" && git init -q && git config user.email a@b.c && git config user.name A )
bash "$HERE/scripts/init.sh" --profile full --level solo --name H --mission m --target "$Q" >/dev/null 2>&1
chk "quiet when no signals" "[ -z \"\$(bash "$HERE/scripts/graduate.sh" "$Q" 2>/dev/null)\" ]"
rm -rf "$P" "$Q"
[ "$fail" = 0 ] && echo "PASS: graduation" || { echo "graduation test failed"; exit 1; }
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tools/workbench/test/graduation.test.sh`
Expected: FAIL (`graduate.sh` not found).

- [ ] **Step 3: Implement `graduate.sh`**

```bash
#!/usr/bin/env bash
# Workbench graduation detector (recommend-only). Reads project signals and
# prints a single recommendation block if the project has outgrown its level,
# else nothing. Always exits 0 — it advises, it never acts.
set -uo pipefail
P="${1:-$PWD}"
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; . "$SELF/lib.sh"; . "$SELF/levels.sh"
CFG="$(il_cfg_dir "$P")/config.json"; [ -f "$CFG" ] || exit 0
level="$(sed -n 's/.*"level"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$CFG" | head -1)"
idx="$(wb_level_index "$level" 2>/dev/null || echo 0)"

signals=""
add() { signals="${signals:+$signals; }$1"; }
# observed signals
tags="$(git -C "$P" tag 2>/dev/null | grep -c . || echo 0)"
[ "${tags:-0}" -gt 0 ] && [ "$idx" -lt 2 ] && add "release tag(s) present"
committers="$(git -C "$P" log --format='%ae' 2>/dev/null | sort -u | grep -c . || echo 0)"
[ "${committers:-0}" -gt 1 ] && [ "$idx" -lt 1 ] && add "more than one committer"
ir="$(ls -1 "$P/.claude/tasks/in-review" 2>/dev/null | grep -c '\.md$' || echo 0)"
cap="$(sed -n 's/.*"in_review_cap"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' "$CFG" | head -1)"; [ -n "$cap" ] || cap=10
[ "${ir:-0}" -ge "$cap" ] && add "in-review cap reached"
repos="$(ls -d "$P"/repos/*/ 2>/dev/null | grep -c . || echo 0)"
[ "${repos:-0}" -gt 1 ] && [ "$idx" -lt 2 ] && add "multiple repos"

[ -z "$signals" ] && exit 0
next="$(wb_levels | tr ' ' '\n' | sed -n "$((idx+2))p")"; [ -n "$next" ] || exit 0
echo "▲ workbench: consider graduating ${level} → ${next}"
echo "  signals: $signals"
echo "  run /workbench:level up to see exactly which dials change (recommend-only — nothing changes without you)."
exit 0
```

- [ ] **Step 4: Run to verify it passes**

Run: `bash tools/workbench/test/graduation.test.sh` → `PASS: graduation`.

- [ ] **Step 5: Wire into the runner + commit**

Add `graduation` to `test/all.sh`. Run `bash tools/workbench/test/all.sh` → `ALL TESTS PASS`.

```bash
git add -- tools/workbench/scripts/graduate.sh tools/workbench/test/graduation.test.sh tools/workbench/test/all.sh
git commit -m "workbench: graduate.sh — recommend-only graduation signal detector"
```

### Task D2: Surface graduation in the SessionStart brief

**Files:**
- Modify: `tools/workbench/hooks/bin/ground-session.sh`
- Test: `tools/workbench/test/graduation.test.sh` (extend)

**Interfaces:**
- Consumes: `graduate.sh`.
- Produces: the re-ground brief appends the graduation recommendation when one exists.

- [ ] **Step 1: Write the failing test**

Append to `graduation.test.sh` (reuse `$P` before cleanup, or rebuild):

```bash
P2="$(mktemp -d)"; ( cd "$P2" && git init -q && git config user.email a@b.c && git config user.name A )
bash "$HERE/scripts/init.sh" --profile full --level solo --name G2 --mission m --target "$P2" >/dev/null 2>&1
( cd "$P2" && git add -A && git commit -qm init && git tag v1 )
brief="$( cd "$P2" && NO_COLOR=1 CLAUDE_PROJECT_DIR="$P2" CLAUDE_PLUGIN_ROOT="$HERE" bash "$HERE/hooks/bin/ground-session.sh" )"
chk "brief surfaces graduation" "printf '%s' \"\$brief\" | grep -qi 'graduat'"
rm -rf "$P2"
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tools/workbench/test/graduation.test.sh`
Expected: FAIL ("graduat" not in brief).

- [ ] **Step 3: Implement in `ground-session.sh`**

Before the final `exit 0`, add (using `${CLAUDE_PLUGIN_ROOT}` to locate `graduate.sh`):

```bash
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -x "$CLAUDE_PLUGIN_ROOT/scripts/graduate.sh" ]; then
  grad="$(bash "$CLAUDE_PLUGIN_ROOT/scripts/graduate.sh" "$P" 2>/dev/null)"
  [ -n "$grad" ] && { echo ""; printf '%s\n' "$grad"; }
fi
```

- [ ] **Step 4: Run tests + full suite**

Run: `bash tools/workbench/test/graduation.test.sh` → `PASS: graduation`.
Run: `bash tools/workbench/test/hooks.test.sh` → `PASS: hooks`.
Run: `bash tools/workbench/test/all.sh` → `ALL TESTS PASS`.

- [ ] **Step 5: Commit**

```bash
git add -- tools/workbench
git commit -m "workbench: SessionStart brief surfaces recommend-only graduation nudge"
```

---

## Phase E — Loop engineering

### Task E1: `loop-policy.sh` — autonomy mode for the configured level

**Files:**
- Create: `tools/workbench/scripts/loop-policy.sh`
- Test: `tools/workbench/test/loop-policy.test.sh` (new)

**Interfaces:**
- Consumes: `levels.sh`, `.workbench/config.json` (honors a `dials.loop_autonomy` override before falling back to the level preset).
- Produces: `loop-policy.sh <project_root>` prints exactly one of `auto-continue | suggest-wait | suggest-review`.

- [ ] **Step 1: Write the failing test**

Create `tools/workbench/test/loop-policy.test.sh`:

```bash
#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail=0
chk() { if eval "$2"; then echo "ok: $1"; else echo "FAIL: $1" >&2; fail=1; fi; }

S="$(mktemp -d)"; bash "$HERE/scripts/init.sh" --profile full --level solo  --name S --mission m --target "$S" >/dev/null 2>&1
C="$(mktemp -d)"; bash "$HERE/scripts/init.sh" --profile full --level crew  --name C --mission m --target "$C" >/dev/null 2>&1
chk "solo -> auto-continue" "[ \"\$(bash "$HERE/scripts/loop-policy.sh" "$S")\" = auto-continue ]"
chk "crew -> suggest-wait"  "[ \"\$(bash "$HERE/scripts/loop-policy.sh" "$C")\" = suggest-wait ]"
# dial override beats the level preset
sed -i 's/"loop_autonomy": "auto-continue"/"loop_autonomy": "suggest-wait"/' "$S/.workbench/config.json"
chk "override beats preset"  "[ \"\$(bash "$HERE/scripts/loop-policy.sh" "$S")\" = suggest-wait ]"
rm -rf "$S" "$C"
[ "$fail" = 0 ] && echo "PASS: loop-policy" || { echo "loop-policy test failed"; exit 1; }
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tools/workbench/test/loop-policy.test.sh`
Expected: FAIL (`loop-policy.sh` not found).

- [ ] **Step 3: Implement `loop-policy.sh`**

```bash
#!/usr/bin/env bash
# Workbench loop-autonomy resolver. Prints the loop autonomy mode for a project:
# an explicit dials.loop_autonomy override wins, else the level preset.
set -uo pipefail
P="${1:-$PWD}"
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; . "$SELF/lib.sh"; . "$SELF/levels.sh"
CFG="$(il_cfg_dir "$P")/config.json"
mode="$(sed -n 's/.*"loop_autonomy"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$CFG" 2>/dev/null | head -1)"
if [ -z "$mode" ]; then
  level="$(sed -n 's/.*"level"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$CFG" 2>/dev/null | head -1)"
  mode="$(wb_level_dials "${level:-solo}" 2>/dev/null | sed -n 's/^loop_autonomy=//p')"
fi
printf '%s\n' "${mode:-auto-continue}"
```

- [ ] **Step 4: Run to verify it passes + wire runner**

Run: `bash tools/workbench/test/loop-policy.test.sh` → `PASS: loop-policy`.
Add `loop-policy` to `test/all.sh`. Run `bash tools/workbench/test/all.sh` → `ALL TESTS PASS`.

- [ ] **Step 5: Commit**

```bash
git add -- tools/workbench/scripts/loop-policy.sh tools/workbench/test/loop-policy.test.sh tools/workbench/test/all.sh
git commit -m "workbench: loop-policy.sh — level-aware loop autonomy (override beats preset)"
```

### Task E2: Encode the loop rule in the orchestration skill + `/workbench:loop`

**Files:**
- Modify: `tools/workbench/skills/orchestration/SKILL.md`, `tools/workbench/commands/loop.md`
- Test: `tools/workbench/test/orchestration.test.sh` (extend)

**Interfaces:**
- Consumes: `loop-policy.sh`.
- Produces: the orchestration skill + loop command document the universal loop rule and read autonomy from `loop-policy.sh`.

- [ ] **Step 1: Write the failing test**

Append to `tools/workbench/test/orchestration.test.sh` before its PASS line:

```bash
OS="$HERE/skills/orchestration/SKILL.md"; LC="$HERE/commands/loop.md"
chk "loop rule: bugs auto-file"        "grep -qi 'bug' '$OS' && grep -qi 'auto.?file\|automatically.*task' '$OS'"
chk "loop rule: features suggested"    "grep -qi 'suggest' '$OS' && grep -qi 'never auto-built\|not auto-built\|never automatically build' '$OS'"
chk "loop reads autonomy policy"       "grep -q 'loop-policy.sh' '$OS' || grep -q 'loop-policy.sh' '$LC'"
chk "loop: autonomy modes named"       "grep -qi 'auto-continue' '$OS' && grep -qi 'suggest-wait' '$OS'"
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tools/workbench/test/orchestration.test.sh`
Expected: FAIL on the loop-rule assertions.

- [ ] **Step 3: Update the orchestration skill + loop command**

Add a **Loop engineering** section to `skills/orchestration/SKILL.md`: the cycle (brainstorm → plan → loop-to-build → replenish); the carved rule — **bugs auto-file as tasks (never merely suggested); new features/improvements are suggested, never auto-built**; and that on queue-drain behavior is governed by `bash "${CLAUDE_PLUGIN_ROOT}/scripts/loop-policy.sh" "${CLAUDE_PROJECT_DIR}"` returning `auto-continue` (auto-promote top suggestion + keep going), `suggest-wait` (present + wait), or `suggest-review` (present + route through review). Reference the same from `commands/loop.md`.

- [ ] **Step 4: Run tests**

Run: `bash tools/workbench/test/orchestration.test.sh` → `PASS: orchestration`.
Run: `bash tools/workbench/test/all.sh` → `ALL TESTS PASS`.

- [ ] **Step 5: Commit**

```bash
git add -- tools/workbench/skills/orchestration/SKILL.md tools/workbench/commands/loop.md tools/workbench/test/orchestration.test.sh
git commit -m "workbench: encode loop rule (bug-auto/feature-suggest) + level-aware autonomy in orchestration"
```

---

## Self-Review

**Spec coverage:**
- §2 identity/front door → A1–A3 (rename) + B3 (single `/workbench`). ✓
- §3.1 levels → B1 (`wb_levels`/index). ✓
- §3.2 presets-over-dials + override → B1 (`wb_level_dials`) + B2 (config) + E1 (override beats preset). ✓
- §3.3 dial matrix → B1 (all dials incl. loop_autonomy). ✓ (architecture/graphify dials are *recorded* here; their *behavior* is Spec 4.)
- §3.4 lifecycle + `staged`/`release-candidate` → B2 (dirs) + C1 (transitions). ✓
- §3.5 recommend-only graduation → D1 + D2. ✓
- §3.6 loop engineering (bug-auto/feature-suggest, autonomy-by-level) → E1 + E2. ✓
- §4 context backbone → **explicitly out of scope** for this plan (Spec 4); only the `architecture`/`graphify` dials are recorded. Noted, not a gap.
- §7 migration → A2 (read-compat) + A4 (beebeeb move). ✓

**Placeholder scan:** No TBD/TODO; every code step shows the code; every test step shows assertions + expected output. ✓

**Type/name consistency:** `wb_levels`, `wb_level_index`, `wb_level_dials`, `wb_level_lifecycle` used consistently across B1/B2/C1/D1/E1. `il_cfg_dir` defined in A2, reused in C1/D1/E1. Loop modes `auto-continue|suggest-wait|suggest-review` consistent between B1, E1, E2. Config keys `workbench.level`, `dials.loop_autonomy` consistent between B2, E1. ✓

**Note on dial-matrix headline vs directories:** the spec's "3/4/5/6 stages" headline counts the deploy path; the directory sets in Global Constraints additionally always carry `verified` + `decisions`. `wb_level_lifecycle` is the single source of truth the plan uses; the headline numbers are narrative only.
