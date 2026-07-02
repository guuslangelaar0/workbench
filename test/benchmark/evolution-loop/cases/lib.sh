#!/usr/bin/env bash
# Shared helpers for evolution-loop eval cases. Sourced by each case's oracle.sh /
# simulate.sh / setup.sh with CASE_DIR, FIXTURE, and P (the seeded project dir) already
# set by run.sh. No jq dependency (matches the rest of this repo's shell conventions).
#
# These paths match the REAL implementation (scripts/evolve.sh, templates/schemas/
# personas.schema.json): the persona roster + trigger knobs live in a dedicated
# .workbench/evolution/personas.json (NOT .workbench/config.json), and the ledger is
# a sibling file in that same directory.
EVOLUTION_ROSTER_PATH=".workbench/evolution/personas.json"
IDEAS_LEDGER_PATH=".workbench/evolution/ideas-log.md"

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

# el_fill_task <path> <why> <criteria_block> <scenarios_block> — the ONE part of a
# summit no offline harness can drive for real: the persona-panel LLM's prose. Every
# other step (scaffolding via task-new.sh, ledger entries via evolve.sh log, the
# trigger via evolve.sh check, retro selection via evolve.sh retro-candidates) is
# exercised for real against evolve.sh; only this content-authoring step is a
# necessary stand-in, and it is isolated to this one helper so it's auditable as
# exactly the gap the review called out (case-by-case content, not the mechanism).
el_fill_task() { # <path> <why-paragraph> <criteria-lines> <scenario-lines>
  local f="$1" why="$2" criteria="$3" scenarios="$4"
  python3 - "$f" "$why" "$criteria" "$scenarios" <<'PYEOF'
import sys
p, why, criteria, scenarios = sys.argv[1:5]
s = open(p).read()
s = s.replace("(one paragraph: the user-facing reason this exists)", why)
s = s.replace(
    "<!-- the checkable definition of done, written BEFORE dispatch. Replace the placeholder. -->\n- [ ] ...",
    "<!-- the checkable definition of done, written BEFORE dispatch. Replace the placeholder. -->\n" + criteria,
)
s = s.replace("- Happy path: ...\n- Edge / negative: ...", scenarios)
open(p, "w").write(s)
PYEOF
}
