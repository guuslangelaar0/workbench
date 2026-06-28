#!/usr/bin/env bash
# SQ-1 — the suggestion surface: a recommend-only home for the loop's recommendations.
# Producers file keyed (deduped) suggestions; the human lists/acts/dismisses; severity
# ranks warn>recommend>info; graduate.sh is wired as the first producer.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # workbench
SUG="$HERE/scripts/suggest.sh"
fail=0
chk() { if eval "$2"; then echo "ok: $1"; else echo "FAIL: $1" >&2; fail=1; fi; }

DIR="$(mktemp -d)"
bash "$HERE/scripts/init.sh" --name "Sug Co" --level crew --target "$DIR" >/dev/null 2>&1
STORE="$DIR/.workbench/suggestions"

# add: creates a keyed file with open status
bash "$SUG" add --key graduate-pair --severity recommend --title "Graduate solo → pair" \
  --why "two committers" --how "/workbench:level up" --source graduate --target "$DIR" >/dev/null 2>&1
chk "add: suggestion file created"   "[ -f '$STORE/graduate-pair.suggest' ]"
chk "add: status open"               "grep -q '^status=open\$' '$STORE/graduate-pair.suggest'"
chk "add: severity recorded"         "grep -q '^severity=recommend\$' '$STORE/graduate-pair.suggest'"
chk "add: how recorded"              "grep -q '^how=/workbench:level up\$' '$STORE/graduate-pair.suggest'"

# dedup: re-adding the same key is a no-op (does not duplicate or overwrite)
bash "$SUG" add --key graduate-pair --severity warn --title "DIFFERENT" --target "$DIR" >/dev/null 2>&1
chk "dedup: title unchanged"         "grep -q '^title=Graduate solo → pair\$' '$STORE/graduate-pair.suggest'"
chk "dedup: severity unchanged"      "grep -q '^severity=recommend\$' '$STORE/graduate-pair.suggest'"
chk "dedup: exactly one file"        "[ \"\$(ls '$STORE'/*.suggest | wc -l)\" -eq 1 ]"

# add a warn-level one + an info one to test ranking
bash "$SUG" add --key gaming-0123 --severity warn --title "Test deleted while claiming pass" --source gate-integrity --target "$DIR" >/dev/null 2>&1
bash "$SUG" add --key info-note --severity info --title "FYI something" --target "$DIR" >/dev/null 2>&1

# list: warn ranks above recommend above info
LIST="$(bash "$SUG" list --target "$DIR" 2>/dev/null)"
chk "list: shows all three titles"   "printf '%s' \"\$LIST\" | grep -q 'Test deleted' && printf '%s' \"\$LIST\" | grep -q 'Graduate solo' && printf '%s' \"\$LIST\" | grep -q 'FYI something'"
warn_ln="$(printf '%s\n' "$LIST" | grep -n 'Test deleted' | head -1 | cut -d: -f1)"
rec_ln="$(printf '%s\n' "$LIST" | grep -n 'Graduate solo' | head -1 | cut -d: -f1)"
info_ln="$(printf '%s\n' "$LIST" | grep -n 'FYI something' | head -1 | cut -d: -f1)"
chk "rank: warn before recommend"    "[ '$warn_ln' -lt '$rec_ln' ]"
chk "rank: recommend before info"    "[ '$rec_ln' -lt '$info_ln' ]"

# top N: compact, capped
TOP="$(bash "$SUG" top 2 --target "$DIR" 2>/dev/null)"
chk "top: warn item present"         "printf '%s' \"\$TOP\" | grep -q 'Test deleted'"
chk "top: info item excluded (N=2)"  "! printf '%s' \"\$TOP\" | grep -q 'FYI something'"

# act: prints the how, marks acted, drops from the open list.
# NOTE: capture output into vars before grep — `cmd | grep -q` under `set -o pipefail`
# spuriously fails when grep matches early and SIGPIPEs the upstream writer.
ACT="$(bash "$SUG" act graduate-pair --target "$DIR" 2>/dev/null)"
chk "act: prints the how command"    "printf '%s' \"\$ACT\" | grep -q '/workbench:level up'"
chk "act: status flips to acted"     "grep -q '^status=acted\$' '$STORE/graduate-pair.suggest'"
OPEN="$(bash "$SUG" list --target "$DIR" 2>/dev/null)"
ALLOUT="$(bash "$SUG" list --all --target "$DIR" 2>/dev/null)"
chk "act: gone from open list"       "! printf '%s' \"\$OPEN\" | grep -q 'Graduate solo'"
chk "act: still visible with --all"  "printf '%s' \"\$ALLOUT\" | grep -q 'Graduate solo'"

# dismiss: won't resurface, and a producer re-emit does NOT resurrect it
bash "$SUG" dismiss gaming-0123 --target "$DIR" >/dev/null 2>&1
chk "dismiss: status dismissed"      "grep -q '^status=dismissed\$' '$STORE/gaming-0123.suggest'"
bash "$SUG" add --key gaming-0123 --severity warn --title "re-emit" --target "$DIR" >/dev/null 2>&1
chk "dismiss: re-emit is no-op"      "grep -q '^status=dismissed\$' '$STORE/gaming-0123.suggest'"
chk "dismiss: stays out of open list" "! bash '$SUG' list --target '$DIR' 2>/dev/null | grep -q 'Test deleted'"

# clear: removes the file
bash "$SUG" clear info-note --target "$DIR" >/dev/null 2>&1
chk "clear: file removed"            "[ ! -f '$STORE/info-note.suggest' ]"

# empty store reports cleanly (after clearing the rest)
bash "$SUG" clear graduate-pair --target "$DIR" >/dev/null 2>&1
bash "$SUG" clear gaming-0123 --target "$DIR" >/dev/null 2>&1
chk "empty: 'No suggestions.'"       "bash '$SUG' list --target '$DIR' 2>/dev/null | grep -q 'No suggestions.'"

# producer wiring: graduate.sh files a suggestion as a side effect.
# crew project with >1 committer + a release tag should trigger graduate -> a suggestion.
GDIR="$(mktemp -d)"
bash "$HERE/scripts/init.sh" --name "Grad Co" --level solo --target "$GDIR" >/dev/null 2>&1
( cd "$GDIR" && git init -q && git config user.email a@x.com && git config user.name A \
  && git commit -q --allow-empty -m one \
  && git config user.email b@y.com && git config user.name B \
  && git commit -q --allow-empty -m two ) >/dev/null 2>&1
SELF="$HERE/scripts" bash "$HERE/scripts/graduate.sh" "$GDIR" >/dev/null 2>&1
chk "producer: graduate filed a suggestion" "ls '$GDIR/.workbench/suggestions/'graduate-*.suggest >/dev/null 2>&1"
rm -rf "$GDIR"

rm -rf "$DIR"
[ "$fail" = 0 ] && echo "PASS: suggest" || { echo "suggest test failed"; exit 1; }
