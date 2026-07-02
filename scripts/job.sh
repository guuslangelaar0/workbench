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

job_duplicate_ordinal() {
  local job_id="$1" suffix stem
  if [[ "$job_id" =~ -[0-9]+$ ]]; then
    suffix="${job_id##*-}"
    stem="${job_id%-${suffix}}"
    if [[ "$stem" =~ -[0-9]{8}T[0-9]{6}Z$ ]]; then
      printf '%s\n' "$suffix"
      return
    fi
  fi
  printf '1\n'
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

job_reserve_file() {
  local file="$1"
  ( set -C; : > "$file" ) 2>/dev/null
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
    base_job_id="${TYPE%%-*}-${TASK_ID}-${ts}"
    [ "$TYPE" = "codex-engineer" ] && base_job_id="codex-${TASK_ID}-${ts}"
    suffix=1
    while :; do
      if [ "$suffix" = 1 ]; then
        JOB_ID="$base_job_id"
      else
        JOB_ID="${base_job_id}-${suffix}"
      fi
      file="$dir/$JOB_ID.job"
      if job_reserve_file "$file"; then
        break
      fi
      suffix=$((suffix + 1))
    done
    [ -n "$BRANCH" ] || BRANCH="$(git -C "$TARGET" branch --show-current 2>/dev/null || true)"
    [ -n "$TASK_FILE" ] || TASK_FILE=".claude/tasks"
    if ! job_write "$file" "$JOB_ID" "$TYPE" "$TASK_ID" "$OWNER" "running" "$iso" "$iso" "$BRANCH" "$RUNTIME_MODE" "$RUNTIME_FLAGS" "$TASK_FILE" ".workbench/lanes/$TASK_ID.lane" "/workbench:codex-engineer $TASK_ID --reconcile" "$OUTPUT_REF" "$SUMMARY" "/workbench:verify $TASK_ID"; then
      rm -f "$file"
      exit 1
    fi
    echo "job: started $JOB_ID task=$TASK_ID status=running"
    ;;
  update)
    JOB_ID="${1:-}"; shift || true
    [ -n "$JOB_ID" ] || { echo "job.sh: update requires <job-id>" >&2; exit 64; }
    STATUS=""; SUMMARY=""; OUTPUT_REF=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --target) TARGET="${2:-}"; shift 2 ;;
        --status) STATUS="${2:-}"; shift 2 ;;
        --summary) SUMMARY="${2:-}"; shift 2 ;;
        --output-ref) OUTPUT_REF="${2:-}"; shift 2 ;;
        *) echo "job.sh: unknown update arg '$1'" >&2; exit 64 ;;
      esac
    done
    file="$(job_file "$TARGET" "$JOB_ID")"
    [ -f "$file" ] || { echo "job.sh: no job '$JOB_ID'" >&2; exit 1; }
    [ -n "$STATUS" ] || STATUS="$(job_get "$file" status)"
    [ -n "$SUMMARY" ] || SUMMARY="$(job_get "$file" last_summary)"
    [ -n "$OUTPUT_REF" ] || OUTPUT_REF="$(job_get "$file" output_ref)"
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
    best=""; best_started=""; best_job_id=""; best_ordinal=0
    for file in "$dir"/*.job; do
      [ -e "$file" ] || continue
      job_valid "$file" || continue
      [ "$(job_get "$file" task_id)" = "$TASK_ID" ] || continue
      started="$(job_get "$file" started_at)"
      job_id="$(job_get "$file" job_id)"
      ordinal="$(job_duplicate_ordinal "$job_id")"
      if [ -z "$best" ] || [ "$started" \> "$best_started" ] || { [ "$started" = "$best_started" ] && { [ "$ordinal" -gt "$best_ordinal" ] || { [ "$ordinal" -eq "$best_ordinal" ] && [ "$job_id" \> "$best_job_id" ]; }; }; }; then
        best="$file"
        best_started="$started"
        best_job_id="$job_id"
        best_ordinal="$ordinal"
      fi
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
