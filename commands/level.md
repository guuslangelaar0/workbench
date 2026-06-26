---
description: Show the current workbench maturity level and dials, or change the level (status | up | down | <level>)
allowed-tools: ["Bash", "Read", "AskUserQuestion"]
argument-hint: "[status|up|down|<level>]"
---

You are the `/workbench:level` command. Read `$ARGUMENTS` and act on it.

## Resolve the config

Read `${CLAUDE_PROJECT_DIR}/.workbench/config.json`. If it does not exist, tell the user:
"This project isn't configured yet. Run `/workbench` to set it up." and stop.

Parse:
- `workbench.level` — the current level (e.g. `"solo"`)
- `dials` — the current dial map (JSON object)

Source the levels library with Bash so you can call `wb_level_index`, `wb_level_dials`, and `wb_level_lifecycle`:

```bash
. "${CLAUDE_PLUGIN_ROOT}/scripts/levels.sh"
```

---

## `status` (default when no argument is given)

Print:

```
Level:  <current_level>
Dials:
  team             = <value>
  release          = <value>
  decomposition    = <value>
  architecture     = <value>
  surfaces         = <value>
  graphify         = <value>
  loop_autonomy    = <value>
```

Tell the user:
- The ladder order: **solo → pair → crew → fleet**
- Which level is one step up and one step down (if applicable)
- A one-line hint: "Run `/workbench:level up` to move to `<next>`, or `/workbench:level <name>` to jump directly."

---

## `up` / `down` / `<level>`

Compute the target level:
- `up`   → current index + 1; if already at `fleet`, tell the user they are at the top and stop.
- `down` → current index − 1; if already at `solo`, tell the user they are at the bottom and stop.
- `<level>` → validate it is one of `solo|pair|crew|fleet`; if not, report an error and stop.
- If the target level equals the current level, say "Already at `<level>`. No change." and stop.

### Show the dial diff before applying

Run `wb_level_dials <current>` and `wb_level_dials <target>` with your Bash tool and compare them line by line.

Print a clear **before → after** table showing **which dials change**:

```
Dial changes (current=<current> → target=<target>):
  team             solo        → pair
  release          push-to-main → feature-branch
  ...              (unchanged dials are not shown)
```

Print the lifecycle dirs that will be **added** (present in `wb_level_lifecycle <target>` but not in `wb_level_lifecycle <current>`):

```
Lifecycle dirs to add:
  .claude/tasks/in-review/
```

If no dirs change (moving down), note that existing dirs are **not removed** — only additions are safe; removal requires manual cleanup.

### Confirm before applying

Ask the user to confirm with `AskUserQuestion`:

```
Apply level change from '<current>' to '<target>'? (yes/no)
```

If the user answers anything other than `yes`, print "Cancelled." and stop.

### Apply

Run `init.sh` in non-destructive mode (it only adds missing stage dirs and re-stamps level and dials; existing tasks are untouched):

```bash
_wb_cfg="${CLAUDE_PROJECT_DIR}/.workbench/config.json"
_wb_name="$(sed -n 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$_wb_cfg" | head -1)"
[ -n "$_wb_name" ] || _wb_name="project"
bash "${CLAUDE_PLUGIN_ROOT}/scripts/init.sh" \
  --name "$_wb_name" \
  --level "<target>" \
  --target "${CLAUDE_PROJECT_DIR}"
```

After `init.sh` succeeds, report:

```
Level updated: <current> → <target>
Dials re-stamped in .workbench/config.json.
Lifecycle dirs added (if any): <list>
Existing tasks are untouched.
```

If `init.sh` exits non-zero, show its output and tell the user the change was NOT applied.
