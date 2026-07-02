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

REAL_DATE="$(command -v date)"
REAL_GIT="$(command -v git)"
mkdir -p "$TMP/bin"
{
  printf '#!/usr/bin/env bash\n'
  printf 'case "$*" in\n'
  printf "  '-u +%%Y%%m%%dT%%H%%M%%SZ') printf '%%s\\n' '20260702T120000Z' ;;\n"
  printf "  '-u +%%Y-%%m-%%dT%%H:%%M:%%SZ') printf '%%s\\n' '2026-07-02T12:00:00Z' ;;\n"
  printf '  *) exec %s "$@" ;;\n' "$REAL_DATE"
  printf 'esac\n'
} > "$TMP/bin/date"
chmod +x "$TMP/bin/date"
{
  printf '#!/usr/bin/env bash\n'
  printf 'if [ "$1" = "-C" ] && [ "$3" = "branch" ] && [ "$4" = "--show-current" ]; then sleep 0.1; exit 0; fi\n'
  printf 'exec %s "$@"\n' "$REAL_GIT"
} > "$TMP/bin/git"
chmod +x "$TMP/bin/git"

CONCURRENT_DIR="$TMP/concurrent-starts"
CONCURRENT_TASK="0066"
mkdir -p "$CONCURRENT_DIR"
pids=()
for n in 1 2 3 4 5 6 7 8 9 10 11 12; do
  PATH="$TMP/bin:$PATH" bash "$HERE/scripts/job.sh" start codex-engineer "$CONCURRENT_TASK" --target "$TMP" > "$CONCURRENT_DIR/$n.out" 2> "$CONCURRENT_DIR/$n.err" &
  pids+=("$!")
done
CONCURRENT_STATUS=0
for pid in "${pids[@]}"; do
  wait "$pid" || CONCURRENT_STATUS=1
done
CONCURRENT_IDS="$CONCURRENT_DIR/ids"
: > "$CONCURRENT_IDS"
for n in 1 2 3 4 5 6 7 8 9 10 11 12; do
  sed -n 's/^job: started //p' "$CONCURRENT_DIR/$n.out" | awk '{print $1}' >> "$CONCURRENT_IDS"
done
CONCURRENT_STARTED="$(grep -c "^codex-$CONCURRENT_TASK-" "$CONCURRENT_IDS" || true)"
CONCURRENT_UNIQUE_IDS="$(sort "$CONCURRENT_IDS" | uniq | wc -l | tr -d ' ')"
CONCURRENT_FILE_COUNT="$(find "$TMP/.workbench/jobs" -name "codex-$CONCURRENT_TASK-*.job" | wc -l | tr -d ' ')"
CONCURRENT_MISSING=0
while IFS= read -r concurrent_id; do
  [ -n "$concurrent_id" ] || { CONCURRENT_MISSING=1; continue; }
  [ -f "$TMP/.workbench/jobs/$concurrent_id.job" ] || CONCURRENT_MISSING=1
done < "$CONCURRENT_IDS"
chk "concurrent same-second starts create 12 unique job ids" "[ '$CONCURRENT_STATUS' = 0 ] && [ '$CONCURRENT_STARTED' = 12 ] && [ '$CONCURRENT_UNIQUE_IDS' = 12 ]"
chk "concurrent same-second starts keep 12 job files" "[ '$CONCURRENT_FILE_COUNT' = 12 ] && [ '$CONCURRENT_MISSING' = 0 ]"

COLLIDE_ONE="$(PATH="$TMP/bin:$PATH" bash "$HERE/scripts/job.sh" start codex-engineer 0077 --target "$TMP")"
COLLIDE_TWO="$(PATH="$TMP/bin:$PATH" bash "$HERE/scripts/job.sh" start codex-engineer 0077 --target "$TMP")"
COLLIDE_ID_ONE="$(printf '%s\n' "$COLLIDE_ONE" | sed -n 's/^job: started //p' | awk '{print $1}')"
COLLIDE_ID_TWO="$(printf '%s\n' "$COLLIDE_TWO" | sed -n 's/^job: started //p' | awk '{print $1}')"
COLLIDE_COUNT="$(find "$TMP/.workbench/jobs" -name 'codex-0077-*.job' | wc -l | tr -d ' ')"
chk "same-second starts create distinct job ids" "[ -n '$COLLIDE_ID_ONE' ] && [ -n '$COLLIDE_ID_TWO' ] && [ '$COLLIDE_ID_ONE' != '$COLLIDE_ID_TWO' ]"
chk "same-second starts keep both job files" "[ '$COLLIDE_COUNT' = 2 ] && [ -f '$TMP/.workbench/jobs/$COLLIDE_ID_ONE.job' ] && [ -f '$TMP/.workbench/jobs/$COLLIDE_ID_TWO.job' ]"

DUP_LAST_ID=""
DUP_COUNT=0
for _ in 1 2 3 4 5 6 7 8 9 10; do
  DUP_OUT="$(PATH="$TMP/bin:$PATH" bash "$HERE/scripts/job.sh" start codex-engineer 0088 --target "$TMP")"
  DUP_LAST_ID="$(printf '%s\n' "$DUP_OUT" | sed -n 's/^job: started //p' | awk '{print $1}')"
  [ -n "$DUP_LAST_ID" ] && DUP_COUNT=$((DUP_COUNT + 1))
done
DUP_LATEST_OUT="$(bash "$HERE/scripts/job.sh" latest 0088 --target "$TMP")"
chk "latest resolves newest same-second duplicate job numerically" "[ '$DUP_COUNT' = 10 ] && [ '$DUP_LATEST_OUT' = '$DUP_LAST_ID' ]"

cat > "$TMP/.workbench/jobs/a-new.job" <<'JOB'
job_id=a-new
type=codex-engineer
task_id=0099
task_file=.claude/tasks
owner=codex
status=running
started_at=2026-07-02T12:01:00Z
updated_at=2026-07-02T12:01:00Z
branch=feature/jobs
runtime_mode=foreground
runtime_flags=
lane_file=.workbench/lanes/0099.lane
reconcile_command=/workbench:codex-engineer 0099 --reconcile
output_ref=
last_summary=new
verification_hint=/workbench:verify 0099
JOB
cat > "$TMP/.workbench/jobs/z-old.job" <<'JOB'
job_id=z-old
type=codex-engineer
task_id=0099
task_file=.claude/tasks
owner=codex
status=running
started_at=2026-07-02T12:00:00Z
updated_at=2026-07-02T12:00:00Z
branch=feature/jobs
runtime_mode=foreground
runtime_flags=
lane_file=.workbench/lanes/0099.lane
reconcile_command=/workbench:codex-engineer 0099 --reconcile
output_ref=
last_summary=old
verification_hint=/workbench:verify 0099
JOB
LATEST_ORDER_OUT="$(bash "$HERE/scripts/job.sh" latest 0099 --target "$TMP")"
chk "latest resolves newest job by timestamp" "[ '$LATEST_ORDER_OUT' = 'a-new' ]"

[ "$fail" = 0 ] && echo "PASS: job" || { echo "job test failed"; exit 1; }
