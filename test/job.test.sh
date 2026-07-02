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
