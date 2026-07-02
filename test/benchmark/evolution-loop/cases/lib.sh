#!/usr/bin/env bash
# Shared helpers for evolution-loop eval cases. Sourced by each case's oracle.sh /
# simulate.sh / setup.sh with CASE_DIR, FIXTURE, and P (the seeded project dir) already
# set by run.sh. No jq dependency (matches the rest of this repo's shell conventions).
#
# ASSUMPTION (see cases/README.md): the design spec never names where the persona-roster
# / trigger config lives. EVOLUTION_CONFIG_PATH below is this suite's guess, modeled on
# the existing .workbench/config.json dial_overrides convention. If the landed
# implementation uses a different path, update this one constant.
EVOLUTION_CONFIG_PATH=".workbench/config.json"
IDEAS_LEDGER_PATH=".claude/admin-evolution/ideas-log.md"

# el_seed <fixture_dir> <dest_dir> — copy the synthetic project fixture into a scratch dir.
el_seed() {
  local fixture="$1" dest="$2"
  mkdir -p "$dest"
  cp -r "$fixture/." "$dest/"
}

# el_task_file_valid <path> — a minimal structural check that a task file matches the
# canonical template (templates/minimal/tasks/task.md.tmpl): required headers present,
# AND the placeholder text has actually been replaced (not just the skeleton copied verbatim).
el_task_file_valid() {
  local f="$1"
  [ -f "$f" ] || return 1
  grep -q '^\*\*Status:\*\*' "$f" || return 1
  grep -q '^\*\*Track:\*\*' "$f" || return 1
  grep -q '^\*\*Verification:\*\*' "$f" || return 1
  grep -q '^## Why' "$f" || return 1
  grep -q '^## Acceptance criteria' "$f" || return 1
  grep -q '^## Verification ladder' "$f" || return 1
  # reject an unfilled placeholder skeleton — the literal template prose must be GONE
  grep -q 'one paragraph: the user-facing reason this exists' "$f" && return 1
  grep -qE '^\s*-\s*\[ \]\s*\.\.\.\s*$' "$f" && return 1
  # a real acceptance criterion: at least one checkbox line with actual content
  grep -qE '^\s*-\s*\[[ x]\]\s*\S+' "$f" || return 1
  return 0
}

# el_track_is <path> <track> — the synthesized task declares the given Track.
el_track_is() {
  grep -qiE "^\*\*Track:\*\*[[:space:]]*$2\b" "$1"
}

# el_ledger_flat <ledger_path> — the ledger with each "- <date> —" bullet entry
# collapsed onto one logical line. Ledger entries are hand/LLM-written prose that
# WRAPS across multiple physical lines (see fixture/.../ideas-log.md) — any check
# for a phrase that might span a line break must normalize this first, or it
# silently never matches and every oracle in this suite would false-negative.
el_ledger_flat() {
  awk '
    /^- / { if (buf != "") print buf; buf = $0; next }
    /^[[:space:]]/ { sub(/^[[:space:]]+/, " "); buf = buf $0; next }
    { if (buf != "") print buf; buf = "" }
    END { if (buf != "") print buf }
  ' "$1" 2>/dev/null
}

# el_ledger_has_disposition_for <ledger_path> <task_id> <pattern> — a ledger entry
# (wrap-normalized) referencing task #<id> whose disposition text matches <pattern>.
el_ledger_has_disposition_for() {
  local ledger="$1" id="$2" pattern="$3"
  el_ledger_flat "$ledger" | grep -iE "#${id}\b" | grep -qiE "$pattern"
}

# el_ledger_count_retro_entries_for <ledger_path> <task_id> — how many (wrap-
# normalized) "retrospective audit of task #<id>" entries exist. Use this instead of
# a raw grep -c so a re-audit is caught even when the original entry wraps.
el_ledger_count_retro_entries_for() {
  el_ledger_flat "$1" | grep -ciE "retrospective audit of task #${2}\b"
}

# el_ledger_has_retro_entry_for <ledger_path> <task_id> — an existing "retrospective
# audit of task #<id>" entry (the dedup marker per the spec's "Ideas ledger" section).
el_ledger_has_retro_entry_for() {
  [ "$(el_ledger_count_retro_entries_for "$1" "$2")" -ge 1 ]
}

# el_count_unblocked_backlog <project_dir> <track> — count backlog task files for a
# track that are not blocked (Blocked-by is "(none)" or absent).
el_count_unblocked_backlog() {
  local proj="$1" track="$2" n=0 f
  for f in "$proj/.claude/tasks/backlog/"*.md; do
    [ -f "$f" ] || continue
    grep -qiE "^\*\*Track:\*\*[[:space:]]*$track\b" "$f" || continue
    grep -qiE '^\*\*Blocked-by:\*\*[[:space:]]*\(none\)' "$f" || continue
    n=$((n+1))
  done
  echo "$n"
}
