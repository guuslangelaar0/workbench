# Workbench Codex Lane Observability Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Track Codex engineer lanes as durable Workbench jobs so leads can reconcile dropped callbacks and see Codex work in Mission Control and mesh jobs.

**Architecture:** Add a disk-first job ledger under `.workbench/jobs/` with a focused `scripts/job.sh` helper. `/workbench:codex-engineer` creates and updates those records, while `/workbench:mc` and `/workbench:mesh jobs` render the same canonical disk state. Mesh remains a projection; the job ledger works even when the mesh daemon is not running.

**Tech Stack:** Bash shell helpers, Workbench markdown slash commands, existing `.workbench` file state, existing shell test harness, Rust mesh binary only where already required by mesh tests.

## Global Constraints

- Do not call another plugin's private Codex runtime.
- Do not require Codex credentials, network access, or live Claude Code in `test/all.sh`.
- Disk job records are canonical; mesh and Mission Control read or project them.
- Codex implements; Workbench owns review, verification, and lifecycle advancement.
- Do not bump plugin version during feature implementation; use `CHANGELOG.md` `[Unreleased]` only.
- Keep terminal job output compact and one-line per active job.

---

## File Structure

- Create `scripts/job.sh`: owns Workbench job record create/update/list/latest/show behavior. It uses simple `key=value` files like `scripts/lane.sh`.
- Create `test/job.test.sh`: direct behavioral coverage for the job ledger helper.
- Modify `test/all.sh`: include the new `job` suite.
- Modify `commands/codex-engineer.md`: document and require job ledger creation/update during dispatch and reconcile.
- Modify `test/codex.test.sh`: structural assertions that the command uses the job ledger and keeps callback-less reconcile guidance.
- Modify `scripts/mc.sh`: render an active `Jobs` section from `scripts/job.sh list --active`.
- Modify `test/mc.test.sh`: assert Mission Control renders active Codex jobs and hides terminal jobs.
- Modify `scripts/mesh.sh`: make `mesh.sh jobs` prefer Workbench job ledger output when records exist, otherwise fall back to the Rust mesh binary.
- Modify `test/mesh-ops.test.sh`: assert `/workbench:mesh jobs` can show a disk Codex job.
- Modify `skills/codex-bridge/SKILL.md` and `skills/orchestration/SKILL.md`: teach leads to use the job ledger and reconcile before redispatching.
- Modify `README.md`, `docs/commands.md`, and `CHANGELOG.md`: document the observable Codex job behavior.

---

### Task 1: Add the Job Ledger Helper

**Files:**
- Create: `test/job.test.sh`
- Create: `scripts/job.sh`
- Modify: `test/all.sh`

**Interfaces:**
- Consumes: `scripts/lib.sh` function `il_cfg_dir <project_root>`.
- Produces: `scripts/job.sh start|update|list|latest|show` with records under `.workbench/jobs/*.job`.

- [ ] **Step 1: Write the failing job ledger test**

Create `test/job.test.sh`:

```bash
#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail=0
chk() { if eval "$2"; then echo "ok: $1"; else echo "FAIL: $1" >&2; fail=1; fi; }

bash "$HERE/scripts/init.sh" --name "Jobs" --mission "Test." --target "$TMP" >/dev/null 2>&1

START_OUT="$(bash "$HERE/scripts/job.sh" start codex-engineer 0042 --target "$TMP" --owner codex --runtime-mode background --runtime-flags '--model spark --effort high' --branch feature/jobs --summary 'Codex dispatched; waiting for artifacts.')"
JOB_ID="$(printf '%s\n' "$START_OUT" | sed -n 's/^job: started //p' | awk '{print $1}')"

chk "job id printed" "[ -n '$JOB_ID' ]"
chk "job file created" "[ -f '$TMP/.workbench/jobs/$JOB_ID.job' ]"
chk "job records task id" "grep -q '^task_id=0042$' '$TMP/.workbench/jobs/$JOB_ID.job'"
chk "job records type" "grep -q '^type=codex-engineer$' '$TMP/.workbench/jobs/$JOB_ID.job'"
chk "job records owner" "grep -q '^owner=codex$' '$TMP/.workbench/jobs/$JOB_ID.job'"
chk "job records runtime mode" "grep -q '^runtime_mode=background$' '$TMP/.workbench/jobs/$JOB_ID.job'"
chk "job records runtime flags" "grep -q '^runtime_flags=--model spark --effort high$' '$TMP/.workbench/jobs/$JOB_ID.job'"
chk "job records reconcile command" "grep -q '^reconcile_command=/workbench:codex-engineer 0042 --reconcile$' '$TMP/.workbench/jobs/$JOB_ID.job'"

bash "$HERE/scripts/job.sh" update "$JOB_ID" --target "$TMP" --status needs-review --summary 'Artifacts found; run verification.' --output-ref '.workbench/jobs/snapshot.md' >/dev/null
chk "job update changes status" "grep -q '^status=needs-review$' '$TMP/.workbench/jobs/$JOB_ID.job'"
chk "job update changes summary" "grep -q '^last_summary=Artifacts found; run verification.$' '$TMP/.workbench/jobs/$JOB_ID.job'"
chk "job update records output ref" "grep -q '^output_ref=.workbench/jobs/snapshot.md$' '$TMP/.workbench/jobs/$JOB_ID.job'"

LIST_OUT="$(bash "$HERE/scripts/job.sh" list --target "$TMP")"
chk "job list shows codex job" "printf '%s' \"\$LIST_OUT\" | grep -q \"$JOB_ID\" && printf '%s' \"\$LIST_OUT\" | grep -q 'needs-review'"

LATEST_OUT="$(bash "$HERE/scripts/job.sh" latest 0042 --target "$TMP")"
chk "latest resolves task job" "printf '%s' \"\$LATEST_OUT\" | grep -q \"$JOB_ID\""

SHOW_OUT="$(bash "$HERE/scripts/job.sh" show "$JOB_ID" --target "$TMP")"
chk "show prints job record" "printf '%s' \"\$SHOW_OUT\" | grep -q '^job_id=' && printf '%s' \"\$SHOW_OUT\" | grep -q '^status=needs-review$'"

printf 'not a job record\n' > "$TMP/.workbench/jobs/bad.job"
LIST_WARN="$(bash "$HERE/scripts/job.sh" list --target "$TMP" 2>&1 >/dev/null || true)"
chk "malformed job warns but does not fail" "printf '%s' \"\$LIST_WARN\" | grep -q 'skip malformed job'"

bash "$HERE/scripts/job.sh" update "$JOB_ID" --target "$TMP" --status verified --summary 'Verified by Workbench.' >/dev/null
ACTIVE_OUT="$(bash "$HERE/scripts/job.sh" list --active --target "$TMP")"
chk "active list hides terminal job" "! printf '%s' \"\$ACTIVE_OUT\" | grep -q \"$JOB_ID\""

[ "$fail" = 0 ] && echo "PASS: job" || { echo "job test failed"; exit 1; }
```

- [ ] **Step 2: Add the suite to `test/all.sh`**

Change the suite list in `test/all.sh` so `job` runs after `lane`:

```bash
for t in skeleton levels templates soul coord continuity hooks hooks-mode skills setup init command full-scaffold upgrade uninstall doctor self-test codex task-ops lead-purpose park mesh-protocol mesh-auth mesh-service mesh-ops mesh-packaging mesh-command-center mesh-hooks mesh-plugin-outcome epics mc orchestration multilead inception remote remote-guard dogfood lifecycle frontdoor graduation detect-level marketplace architecture arch-drift verification-gate lane job watchdog loop-policy suggest gate-integrity budget cross-model suggest-scan regression-gate deps value-audit metric score benchmark intents expectancy-gate knobs bench release-gate; do
```

- [ ] **Step 3: Run the failing test**

Run:

```bash
bash test/job.test.sh
```

Expected:

```text
bash: .../scripts/job.sh: No such file or directory
```

- [ ] **Step 4: Implement `scripts/job.sh`**

Create `scripts/job.sh`:

```bash
#!/usr/bin/env bash
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SELF_DIR/lib.sh"

TARGET="$PWD"
CMD="${1:-}"
[ -n "$CMD" ] || { echo "job.sh: missing command" >&2; exit 64; }
shift || true

jobs_dir() { printf '%s\n' "$(il_cfg_dir "$1")/jobs"; }
job_file() { printf '%s\n' "$(jobs_dir "$1")/$2.job"; }
now_utc() { date -u +%Y%m%dT%H%M%SZ; }
now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

job_get() {
  local file="$1" key="$2"
  sed -n "s/^${key}=//p" "$file" 2>/dev/null | head -1
}

job_valid() {
  local file="$1"
  [ -f "$file" ] || return 1
  grep -q '^job_id=' "$file" && grep -q '^task_id=' "$file" && grep -q '^status=' "$file"
}

job_write() {
  local file="$1" job_id="$2" type="$3" task_id="$4" owner="$5" status="$6" started="$7" updated="$8" branch="$9" runtime_mode="${10}" runtime_flags="${11}" task_file="${12}" lane_file="${13}" reconcile_command="${14}" output_ref="${15}" last_summary="${16}" verification_hint="${17}"
  {
    printf 'job_id=%s\n' "$job_id"
    printf 'type=%s\n' "$type"
    printf 'task_id=%s\n' "$task_id"
    printf 'task_file=%s\n' "$task_file"
    printf 'owner=%s\n' "$owner"
    printf 'status=%s\n' "$status"
    printf 'started_at=%s\n' "$started"
    printf 'updated_at=%s\n' "$updated"
    printf 'branch=%s\n' "$branch"
    printf 'runtime_mode=%s\n' "$runtime_mode"
    printf 'runtime_flags=%s\n' "$runtime_flags"
    printf 'lane_file=%s\n' "$lane_file"
    printf 'reconcile_command=%s\n' "$reconcile_command"
    printf 'output_ref=%s\n' "$output_ref"
    printf 'last_summary=%s\n' "$last_summary"
    printf 'verification_hint=%s\n' "$verification_hint"
  } > "$file"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --target) TARGET="${2:-}"; shift 2 ;;
    *) break ;;
  esac
done

case "$CMD" in
  start)
    TYPE="${1:-}"; TASK_ID="${2:-}"; shift 2 || true
    [ -n "$TYPE" ] && [ -n "$TASK_ID" ] || { echo "job.sh: start requires <type> <task-id>" >&2; exit 64; }
    OWNER="codex"; RUNTIME_MODE="foreground"; RUNTIME_FLAGS=""; BRANCH=""; SUMMARY="Codex dispatched; waiting for artifacts."; TASK_FILE=""; OUTPUT_REF=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --target) TARGET="${2:-}"; shift 2 ;;
        --owner) OWNER="${2:-}"; shift 2 ;;
        --runtime-mode) RUNTIME_MODE="${2:-}"; shift 2 ;;
        --runtime-flags) RUNTIME_FLAGS="${2:-}"; shift 2 ;;
        --branch) BRANCH="${2:-}"; shift 2 ;;
        --summary) SUMMARY="${2:-}"; shift 2 ;;
        --task-file) TASK_FILE="${2:-}"; shift 2 ;;
        --output-ref) OUTPUT_REF="${2:-}"; shift 2 ;;
        *) echo "job.sh: unknown start arg '$1'" >&2; exit 64 ;;
      esac
    done
    dir="$(jobs_dir "$TARGET")"; mkdir -p "$dir"
    ts="$(now_utc)"; iso="$(now_iso)"
    JOB_ID="${TYPE%%-*}-${TASK_ID}-${ts}"
    [ "$TYPE" = "codex-engineer" ] && JOB_ID="codex-${TASK_ID}-${ts}"
    file="$dir/$JOB_ID.job"
    [ -n "$BRANCH" ] || BRANCH="$(git -C "$TARGET" branch --show-current 2>/dev/null || true)"
    [ -n "$TASK_FILE" ] || TASK_FILE=".claude/tasks"
    job_write "$file" "$JOB_ID" "$TYPE" "$TASK_ID" "$OWNER" "running" "$iso" "$iso" "$BRANCH" "$RUNTIME_MODE" "$RUNTIME_FLAGS" "$TASK_FILE" ".workbench/lanes/$TASK_ID.lane" "/workbench:codex-engineer $TASK_ID --reconcile" "$OUTPUT_REF" "$SUMMARY" "/workbench:verify $TASK_ID"
    echo "job: started $JOB_ID task=$TASK_ID status=running"
    ;;
  update)
    JOB_ID="${1:-}"; shift || true
    [ -n "$JOB_ID" ] || { echo "job.sh: update requires <job-id>" >&2; exit 64; }
    file="$(job_file "$TARGET" "$JOB_ID")"
    [ -f "$file" ] || { echo "job.sh: no job '$JOB_ID'" >&2; exit 1; }
    STATUS="$(job_get "$file" status)"; SUMMARY="$(job_get "$file" last_summary)"; OUTPUT_REF="$(job_get "$file" output_ref)"
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --target) TARGET="${2:-}"; file="$(job_file "$TARGET" "$JOB_ID")"; shift 2 ;;
        --status) STATUS="${2:-}"; shift 2 ;;
        --summary) SUMMARY="${2:-}"; shift 2 ;;
        --output-ref) OUTPUT_REF="${2:-}"; shift 2 ;;
        *) echo "job.sh: unknown update arg '$1'" >&2; exit 64 ;;
      esac
    done
    job_write "$file" "$JOB_ID" "$(job_get "$file" type)" "$(job_get "$file" task_id)" "$(job_get "$file" owner)" "$STATUS" "$(job_get "$file" started_at)" "$(now_iso)" "$(job_get "$file" branch)" "$(job_get "$file" runtime_mode)" "$(job_get "$file" runtime_flags)" "$(job_get "$file" task_file)" "$(job_get "$file" lane_file)" "$(job_get "$file" reconcile_command)" "$OUTPUT_REF" "$SUMMARY" "$(job_get "$file" verification_hint)"
    echo "job: updated $JOB_ID status=$STATUS"
    ;;
  list)
    ACTIVE=0
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --target) TARGET="${2:-}"; shift 2 ;;
        --active) ACTIVE=1; shift ;;
        *) echo "job.sh: unknown list arg '$1'" >&2; exit 64 ;;
      esac
    done
    dir="$(jobs_dir "$TARGET")"; [ -d "$dir" ] || exit 0
    for file in "$dir"/*.job; do
      [ -e "$file" ] || continue
      if ! job_valid "$file"; then echo "job.sh: skip malformed job $(basename "$file")" >&2; continue; fi
      status="$(job_get "$file" status)"
      if [ "$ACTIVE" = 1 ]; then
        case "$status" in verified|cancelled|failed) continue ;; esac
      fi
      printf '%s\t%s\t%s\t%s\t%s\n' "$(job_get "$file" job_id)" "$(job_get "$file" type)" "$(job_get "$file" task_id)" "$status" "$(job_get "$file" last_summary)"
    done | sort
    ;;
  latest)
    TASK_ID="${1:-}"; shift || true
    [ -n "$TASK_ID" ] || { echo "job.sh: latest requires <task-id>" >&2; exit 64; }
    while [ "$#" -gt 0 ]; do
      case "$1" in --target) TARGET="${2:-}"; shift 2 ;; *) echo "job.sh: unknown latest arg '$1'" >&2; exit 64 ;; esac
    done
    dir="$(jobs_dir "$TARGET")"; [ -d "$dir" ] || exit 1
    best=""
    for file in "$dir"/*.job; do
      [ -e "$file" ] || continue
      job_valid "$file" || continue
      [ "$(job_get "$file" task_id)" = "$TASK_ID" ] || continue
      best="$file"
    done
    [ -n "$best" ] || exit 1
    job_get "$best" job_id
    ;;
  show)
    JOB_ID="${1:-}"; shift || true
    [ -n "$JOB_ID" ] || { echo "job.sh: show requires <job-id>" >&2; exit 64; }
    while [ "$#" -gt 0 ]; do
      case "$1" in --target) TARGET="${2:-}"; shift 2 ;; *) echo "job.sh: unknown show arg '$1'" >&2; exit 64 ;; esac
    done
    file="$(job_file "$TARGET" "$JOB_ID")"
    [ -f "$file" ] || { echo "job.sh: no job '$JOB_ID'" >&2; exit 1; }
    cat "$file"
    ;;
  *)
    echo "job.sh: unknown command '$CMD' (start|update|list|latest|show)" >&2
    exit 64
    ;;
esac
```

- [ ] **Step 5: Make the helper executable**

Run:

```bash
chmod +x scripts/job.sh
```

- [ ] **Step 6: Verify the job ledger**

Run:

```bash
bash test/job.test.sh
```

Expected:

```text
PASS: job
```

- [ ] **Step 7: Commit Task 1**

Run:

```bash
git add scripts/job.sh test/job.test.sh test/all.sh
git commit -m "feat: add workbench job ledger"
```

---

### Task 2: Wire Codex Dispatch And Reconcile To Jobs

**Files:**
- Modify: `test/codex.test.sh`
- Modify: `commands/codex-engineer.md`
- Modify: `skills/codex-bridge/SKILL.md`

**Interfaces:**
- Consumes: `scripts/job.sh start codex-engineer <id>`, `scripts/job.sh latest <id>`, `scripts/job.sh update <job-id>`.
- Produces: Codex command contract that creates and reconciles Workbench job records.

- [ ] **Step 1: Add failing Codex job-contract assertions**

Append these checks after the existing disk lane lease checks in `test/codex.test.sh`:

```bash
chk "codex engineer starts workbench job" "grep -q 'job.sh.*start codex-engineer' '$HERE/commands/codex-engineer.md'"
chk "codex engineer updates workbench job" "grep -q 'job.sh.*update' '$HERE/commands/codex-engineer.md'"
chk "codex engineer reconcile reads latest job" "grep -q 'job.sh.*latest' '$HERE/commands/codex-engineer.md'"
chk "codex engineer reports job tracking surfaces" "grep -q '/workbench:mc' '$HERE/commands/codex-engineer.md' && grep -q '/workbench:mesh jobs' '$HERE/commands/codex-engineer.md'"
chk "codex bridge names job ledger" "grep -qi 'job ledger\\|workbench job' '$HERE/skills/codex-bridge/SKILL.md'"
```

- [ ] **Step 2: Run the failing Codex test**

Run:

```bash
bash test/codex.test.sh
```

Expected: the new job assertions fail.

- [ ] **Step 3: Update `commands/codex-engineer.md` dispatch steps**

Add this dispatch step after `lane.sh start` and before appending the task note:

```markdown
9. Start a Workbench job record before invoking Codex:
   `bash "${CLAUDE_PLUGIN_ROOT}/scripts/job.sh" start codex-engineer <id> --target "${CLAUDE_PROJECT_DIR}" --owner codex --runtime-mode "<background|wait|foreground>" --runtime-flags "<runtime flags or empty>" --branch "<current branch>" --task-file "<task file path>" --summary "Codex dispatched; waiting for artifacts."`
   Capture the printed job id. If job creation fails, stop before invoking Codex.

   Tell the user:
   ```text
   Codex job <job-id> started.
   Track it with:
     /workbench:codex-engineer <id> --reconcile
     /workbench:mc
     /workbench:mesh jobs
   ```
```

Renumber the existing later steps.

- [ ] **Step 4: Update the reconcile branch in `commands/codex-engineer.md`**

In the `--reconcile` section, include this exact sequence:

```markdown
- run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/job.sh" latest <id> --target "${CLAUDE_PROJECT_DIR}"` to find the newest Workbench job for the task
- run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/job.sh" show <job-id> --target "${CLAUDE_PROJECT_DIR}"` when a job exists
- classify from job record, lane lease, `claude agents`, task notes, git status, and recent commits
- update the job with `bash "${CLAUDE_PLUGIN_ROOT}/scripts/job.sh" update <job-id> --target "${CLAUDE_PROJECT_DIR}" --status <running|returned|needs-review|failed|dead|verified> --summary "<evidence-based summary>" --output-ref "<task notes, snapshot, or empty>"`
- if no job exists, continue from lane/task/git evidence and say the task predates the job ledger
```

- [ ] **Step 5: Update launch failure handling in `commands/codex-engineer.md`**

Change the failure step to include:

```markdown
If the `Agent` call fails after the Workbench job was created, run:
`bash "${CLAUDE_PLUGIN_ROOT}/scripts/job.sh" update <job-id> --target "${CLAUDE_PROJECT_DIR}" --status failed --summary "Codex launch failed; see task notes."`
Then append a task note saying Codex launch failed and leave the task in `in-development`.
```

- [ ] **Step 6: Update `skills/codex-bridge/SKILL.md`**

Add this bullet after the callback warning:

```markdown
- **Workbench job ledger:** each `/workbench:codex-engineer` dispatch creates a `.workbench/jobs/*.job` record. Treat that record plus lane lease, task notes, git state, and `claude agents` as the reconciliation source. Use `/workbench:mc` or `/workbench:mesh jobs` to inspect active Codex work.
```

- [ ] **Step 7: Verify Codex contract**

Run:

```bash
bash test/codex.test.sh
```

Expected:

```text
PASS: codex
```

- [ ] **Step 8: Commit Task 2**

Run:

```bash
git add commands/codex-engineer.md skills/codex-bridge/SKILL.md test/codex.test.sh
git commit -m "feat: track codex dispatch jobs"
```

---

### Task 3: Show Active Jobs In Mission Control

**Files:**
- Modify: `test/mc.test.sh`
- Modify: `scripts/mc.sh`

**Interfaces:**
- Consumes: `scripts/job.sh list --active --target <root>` rows formatted as `job_id<TAB>type<TAB>task_id<TAB>status<TAB>summary`.
- Produces: A compact `Jobs` section in `/workbench:mc`.

- [ ] **Step 1: Add failing Mission Control assertions**

In `test/mc.test.sh`, after task setup and before capturing `out`, create one active and one terminal job:

```bash
JOB_OUT="$(bash "$HERE/scripts/job.sh" start codex-engineer 0001 --target "$TMP" --owner codex --runtime-mode background --summary 'Codex is editing files.')"
JOB_ID="$(printf '%s\n' "$JOB_OUT" | sed -n 's/^job: started //p' | awk '{print $1}')"
DONE_OUT="$(bash "$HERE/scripts/job.sh" start codex-engineer 0099 --target "$TMP" --owner codex --runtime-mode background --summary 'Already verified.')"
DONE_ID="$(printf '%s\n' "$DONE_OUT" | sed -n 's/^job: started //p' | awk '{print $1}')"
bash "$HERE/scripts/job.sh" update "$DONE_ID" --target "$TMP" --status verified --summary 'Verified by Workbench.' >/dev/null
```

Add these checks after the existing cap check:

```bash
chk "shows Jobs section" "printf '%s' \"\$out\" | grep -q 'Jobs'"
chk "shows active codex job" "printf '%s' \"\$out\" | grep -q \"$JOB_ID\" && printf '%s' \"\$out\" | grep -q 'Codex is editing files.'"
chk "hides terminal codex job" "! printf '%s' \"\$out\" | grep -q \"$DONE_ID\""
```

- [ ] **Step 2: Run the failing Mission Control test**

Run:

```bash
bash test/mc.test.sh
```

Expected: `shows Jobs section` fails.

- [ ] **Step 3: Add the Jobs section to `scripts/mc.sh`**

Insert this block after the `In Development` section and before decisions:

```bash
# ----- active jobs (Codex and other delegated lanes) -----
if [[ -x "$SELF_DIR/job.sh" ]]; then
  jobs="$(bash "$SELF_DIR/job.sh" list --active --target "$ROOT" 2>/dev/null)"
  if [[ -n "$jobs" ]]; then
    section "Jobs"
    while IFS=$'\t' read -r job_id job_type task_id job_status job_summary; do
      [[ -n "$job_id" ]] || continue
      col="$C_AMBER"
      case "$job_status" in
        running|returned) col="$C_AMBER" ;;
        needs-review) col="$C_BLUE" ;;
        dead|failed) col="$C_RED" ;;
      esac
      printf "  ${col}%-24s${C_RESET} %-12s task %-5s ${C_DIM}%s${C_RESET}\n" "$job_id" "$job_status" "$task_id" "$job_summary"
    done <<< "$jobs"
  fi
fi
```

- [ ] **Step 4: Verify Mission Control**

Run:

```bash
bash test/mc.test.sh
```

Expected:

```text
PASS: mc
```

- [ ] **Step 5: Commit Task 3**

Run:

```bash
git add scripts/mc.sh test/mc.test.sh
git commit -m "feat: show active jobs in mission control"
```

---

### Task 4: Project Job Ledger Through `/workbench:mesh jobs`

**Files:**
- Modify: `test/mesh-ops.test.sh`
- Modify: `scripts/mesh.sh`

**Interfaces:**
- Consumes: `scripts/job.sh list --active --target <target>`.
- Produces: `scripts/mesh.sh jobs` output that includes disk Codex jobs when present.

- [ ] **Step 1: Add failing mesh jobs assertion**

In `test/mesh-ops.test.sh`, after the existing `watch` command and before `STATUSLINE_OUTPUT`, add:

```bash
JOB_OUT="$(bash "$HERE/scripts/job.sh" start codex-engineer 0042 --target "$TMP" --owner codex --runtime-mode background --summary 'Codex is implementing checkout.')"
JOB_ID="$(printf '%s\n' "$JOB_OUT" | sed -n 's/^job: started //p' | awk '{print $1}')"
MESH_JOBS_OUT="$(CLAUDE_PLUGIN_ROOT="$HERE" CLAUDE_PROJECT_DIR="$TMP" WORKBENCH_HOME="$HOME_TMP" bash "$HERE/scripts/mesh.sh" jobs)"
```

Add these checks before the final summary:

```bash
chk "mesh jobs shows workbench codex job" "printf '%s' \"\$MESH_JOBS_OUT\" | grep -q \"$JOB_ID\" && printf '%s' \"\$MESH_JOBS_OUT\" | grep -q 'Codex is implementing checkout.'"
chk "mesh jobs includes task id" "printf '%s' \"\$MESH_JOBS_OUT\" | grep -q '0042'"
```

- [ ] **Step 2: Run the failing mesh ops test**

Run:

```bash
bash test/mesh-ops.test.sh
```

Expected: the new mesh jobs assertions fail.

- [ ] **Step 3: Update `scripts/mesh.sh jobs`**

Replace the `jobs)` case body with:

```bash
  jobs)
    if [ -x "$PLUGIN_ROOT/scripts/job.sh" ]; then
      job_out="$(bash "$PLUGIN_ROOT/scripts/job.sh" list --active --target "$TARGET" 2>/dev/null || true)"
      if [ -n "$job_out" ]; then
        printf 'Workbench jobs:\n'
        printf '%s\n' "$job_out" | while IFS=$'\t' read -r job_id job_type task_id job_status job_summary; do
          [ -n "$job_id" ] || continue
          printf '  %s  %s  task:%s  %s\n' "$job_id" "$job_status" "$task_id" "$job_summary"
        done
        exit 0
      fi
    fi
    exec "$BIN" jobs "${PROJECT_ARGS[@]}" "$@"
    ;;
```

- [ ] **Step 4: Verify mesh jobs projection**

Run:

```bash
bash test/mesh-ops.test.sh
```

Expected:

```text
PASS: mesh-ops
```

- [ ] **Step 5: Commit Task 4**

Run:

```bash
git add scripts/mesh.sh test/mesh-ops.test.sh
git commit -m "feat: surface workbench jobs through mesh"
```

---

### Task 5: Update Lead Guidance And User Documentation

**Files:**
- Modify: `skills/orchestration/SKILL.md`
- Modify: `README.md`
- Modify: `docs/commands.md`
- Modify: `CHANGELOG.md`

**Interfaces:**
- Consumes: user-facing behavior from Tasks 1-4.
- Produces: docs and lead behavior that tell users and Claude how to inspect Codex jobs.

- [ ] **Step 1: Add failing documentation checks**

Add these checks to `test/codex.test.sh`:

```bash
chk "orchestration checks active jobs before codex redispatch" "grep -qi 'job.sh.*list --active\\|active jobs' '$HERE/skills/orchestration/SKILL.md'"
chk "README documents codex job observability" "grep -qi 'Codex.*job\\|job.*Codex' '$HERE/README.md' && grep -q '/workbench:mesh jobs' '$HERE/README.md'"
chk "commands docs mention codex reconcile jobs" "grep -qi 'reconcile.*job\\|job.*reconcile' '$HERE/docs/commands.md'"
chk "changelog records codex job observability" "grep -qi 'Codex.*job\\|job.*Codex' '$HERE/CHANGELOG.md'"
```

- [ ] **Step 2: Run the failing documentation checks**

Run:

```bash
bash test/codex.test.sh
```

Expected: the new documentation checks fail.

- [ ] **Step 3: Update `skills/orchestration/SKILL.md`**

Add this rule near the Codex dispatch guidance:

```markdown
- Before re-dispatching a Codex task, inspect active Workbench jobs with `scripts/job.sh list --active --target "$CLAUDE_PROJECT_DIR"` when available. If a Codex job exists, reconcile it with `/workbench:codex-engineer <id> --reconcile` instead of launching a duplicate lane.
```

- [ ] **Step 4: Update README command references**

In the `/workbench:codex-engineer` command row, make the description:

```markdown
| `/workbench:codex-engineer <id>` | Dispatch a task to Codex through the OpenAI Codex plugin while Workbench keeps lifecycle and verification ownership; `--reconcile`, `/workbench:mc`, and `/workbench:mesh jobs` show callback-less Codex lane status. |
```

Add this sentence to the Works With OpenAI Codex bullet:

```markdown
Codex lanes are tracked as Workbench jobs so the lead can reconcile from disk when a callback is dropped.
```

- [ ] **Step 5: Update `docs/commands.md`**

Find the `/workbench:codex-engineer` section or command table row and include:

```markdown
Use `--reconcile` when Codex appears to have finished without returning a callback. Workbench reads the job ledger, lane lease, task notes, git artifacts, and active Claude agents before deciding whether the next action is wait, verify, retry, or re-dispatch.
```

- [ ] **Step 6: Update `CHANGELOG.md`**

Under `[Unreleased]`, add:

```markdown
- Track Codex engineer lanes as durable Workbench jobs so `/workbench:mc`, `/workbench:mesh jobs`, and `/workbench:codex-engineer --reconcile` can show status even when Codex does not send a completion callback.
```

- [ ] **Step 7: Verify docs and guidance**

Run:

```bash
bash test/codex.test.sh
```

Expected:

```text
PASS: codex
```

- [ ] **Step 8: Commit Task 5**

Run:

```bash
git add skills/orchestration/SKILL.md README.md docs/commands.md CHANGELOG.md test/codex.test.sh
git commit -m "docs: explain codex job observability"
```

---

### Task 6: Full Verification

**Files:**
- No planned source edits. Fix only concrete failures discovered by the commands below.

**Interfaces:**
- Consumes: all earlier tasks.
- Produces: a verified feature branch ready for review or release preparation.

- [ ] **Step 1: Run targeted suites**

Run:

```bash
bash test/job.test.sh
bash test/codex.test.sh
bash test/mc.test.sh
bash test/mesh-ops.test.sh
```

Expected:

```text
PASS: job
PASS: codex
PASS: mc
PASS: mesh-ops
```

- [ ] **Step 2: Run the full offline suite**

Run:

```bash
bash test/all.sh
```

Expected:

```text
ALL TESTS PASS
```

- [ ] **Step 3: Validate plugin package**

Run:

```bash
bash scripts/validate-plugin.sh
```

Expected:

```text
OK: workbench ... is publishable
```

- [ ] **Step 4: Check whitespace**

Run:

```bash
git diff --check
```

Expected: no output and exit code 0.

- [ ] **Step 5: Review final branch state**

Run:

```bash
git status --short --branch
git log --oneline --decorate -6
```

Expected: the branch contains the task commits above and no uncommitted changes.
