#!/usr/bin/env bash
# workbench Stop/SubagentStop hook: snapshot cumulative session token usage to disk so
# the loop has spend observability. Reads `transcript_path` + `session_id` from the hook
# payload on stdin, sums the transcript via usage-sum.sh, and writes the latest cumulative
# to <cfg>/usage/current.tsv. ALWAYS exits 0 and FAILS OPEN — never blocks a turn-end.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SELF_DIR/../../scripts/lib.sh" 2>/dev/null || exit 0

payload="$(cat 2>/dev/null || true)"
get() { printf '%s' "$payload" | sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -1; }
tp="$(get transcript_path)"
sid="$(get session_id)"
[ -n "$tp" ] && [ -f "$tp" ] || exit 0

P="$(il_project_root "${CLAUDE_PROJECT_DIR:-$PWD}")"
_cfg="$(il_cfg_dir "$P")"
[ -f "$_cfg/config.json" ] || exit 0
il_hooks_enabled "$P" || exit 0
[ -d "$_cfg" ] || exit 0   # not a workbench project — no-op

sums="$(bash "$SELF_DIR/../../scripts/usage-sum.sh" "$tp" 2>/dev/null)" || exit 0
[ -n "$sums" ] || exit 0

mkdir -p "$_cfg/usage" 2>/dev/null || exit 0
# session_id<TAB>epoch<TAB>input<TAB>output<TAB>cache_read<TAB>cache_write<TAB>turns<TAB>source
printf '%s\t%s\t%s\n' "${sid:-?}" "$(date +%s)" "$sums" > "$_cfg/usage/current.tsv" 2>/dev/null || true
exit 0
