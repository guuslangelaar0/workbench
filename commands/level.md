---
description: Show the current workbench maturity level and dials, or change the level (status | up | down | <level>)
allowed-tools: ["Bash", "Read", "AskUserQuestion"]
argument-hint: "[status|up|down|<level>]"
---

You are the `/workbench:level` command. Read `$ARGUMENTS` and act on it.

## Resolve the config

Read `${CLAUDE_PROJECT_DIR}/.workbench/config.json`. If it does not exist, tell the user:
"This project isn't configured yet. Run `/workbench:workbench` to set it up." and stop.

Parse `workbench.level` using sed — no `jq`:

```bash
CFG="${CLAUDE_PROJECT_DIR}/.workbench/config.json"
level="$(sed -n 's/.*"level"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$CFG" | head -1)"
```

Source the levels library with Bash so you can call `wb_level_index`, `wb_level_dials`, `wb_level_lifecycle`, and `wb_dial`:

```bash
. "${CLAUDE_PLUGIN_ROOT}/scripts/lib.sh"
. "${CLAUDE_PLUGIN_ROOT}/scripts/levels.sh"
```

---

## `status` (default when no argument is given)

Read the level preset via `wb_level_dials "$level"` and check for any `dial_overrides` in the config.

Print:

```
Level:  <current_level>
Dials:
  team             = <value>   [override]   ← only show [override] when dial_overrides has this key
  release          = <value>
  decomposition    = <value>
  architecture     = <value>
  surfaces         = <value>
  graphify         = <value>
  loop_autonomy    = <value>
```

Use `wb_dial "${CLAUDE_PROJECT_DIR}" <dial>` to resolve each dial (override-in-dial_overrides beats level preset automatically).

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

Read the project name with sed — no `jq`:

```bash
CFG="${CLAUDE_PROJECT_DIR}/.workbench/config.json"
proj_name="$(sed -n 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$CFG" | head -1)"
proj_name="${proj_name:-project}"
```

Run `init.sh` in non-destructive mode (it only adds missing stage dirs and upserts the `level` scalar; existing config fields and tasks are untouched):

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/init.sh" \
  --name "$proj_name" \
  --level "<target>" \
  --target "${CLAUDE_PROJECT_DIR}"
```

After `init.sh` succeeds, report:

```
Level updated: <current> → <target>
Level re-stamped in .workbench/config.json (dials are derived at read-time from the level).
Lifecycle dirs added (if any): <list>
Existing tasks are untouched.
```

If `init.sh` exits non-zero, show its output and tell the user the change was NOT applied.

### Single-dial override

To override a single dial without changing the level, write directly into `dial_overrides` in the config:

```bash
# Example: override loop_autonomy to suggest-wait on a solo project
# Use sed to either update an existing key in dial_overrides, or inject it.
# The lead should do this via a targeted sed or python3 one-liner that preserves all other content.
```

Report what was written and remind the user that `wb_dial` will now return the override value for that dial.
