#!/usr/bin/env bash
# workbench Mission Control — a text dashboard for a workbench project. Generalized
# from mission-control/dashboard.sh: project name, lifecycle states, in-review cap,
# repos, and prod URLs all come from .workbench/config.json. Runtime tooling — python3
# is used opportunistically for JSON arrays/objects and degrades to defaults if absent.
#
# Usage: mc.sh [--no-prod] [--no-build]
# Env: MC_PROD_API / MC_PROD_WEB (override config prod URLs), MC_TEAM, NO_COLOR
set -uo pipefail

if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]; then
  C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'; C_RESET=$'\033[0m'
  C_AMBER=$'\033[33m'; C_GREEN=$'\033[32m'; C_RED=$'\033[31m'; C_BLUE=$'\033[34m'; C_GREY=$'\033[90m'
else
  C_BOLD= C_DIM= C_RESET= C_AMBER= C_GREEN= C_RED= C_BLUE= C_GREY=
fi

# locate project root: walk up to a dir containing .claude/tasks
ROOT="$PWD"
while [[ "$ROOT" != "/" ]] && [[ ! -d "$ROOT/.claude/tasks" ]]; do ROOT="$(dirname "$ROOT")"; done
[[ -d "$ROOT/.claude/tasks" ]] || { echo "mc: no .claude/tasks/ found from $PWD upwards" >&2; exit 1; }
cd "$ROOT"
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SELF_DIR/lib.sh"
. "$SELF_DIR/levels.sh"
CFG="$(il_cfg_dir "$ROOT")/config.json"

SHOW_PROD=1 SHOW_BUILD=1
for a in "$@"; do case "$a" in --no-prod) SHOW_PROD=0 ;; --no-build) SHOW_BUILD=0 ;; esac; done

HAVE_PY=0; command -v python3 >/dev/null 2>&1 && HAVE_PY=1
cfg_scalar() { sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$CFG" 2>/dev/null | head -1; }
cfg_int()    { sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p" "$CFG" 2>/dev/null | head -1; }

NAME=""; CAP=10; STATES="backlog in-development in-review verified decisions"
if [[ -f "$CFG" ]]; then
  NAME="$(cfg_scalar name)"
  ci="$(cfg_int in_review_cap)"; [[ -n "$ci" ]] && CAP="$ci"
  # Derive lifecycle states from the level scalar (not persisted lifecycle.states)
  lvl="$(cfg_scalar level)"
  if [[ -n "$lvl" ]]; then
    s="$(wb_level_lifecycle "$lvl" 2>/dev/null || true)"
    [[ -n "$s" ]] && STATES="$s"
  fi
fi
[[ -n "$NAME" ]] || NAME="$(basename "$ROOT")"

NOW="$(date -u +%Y-%m-%d\ %H:%MZ)"
printf "${C_BOLD}%s · Mission Control${C_RESET} %s\n" "$NAME" "$NOW"
printf "${C_GREY}%s${C_RESET}\n" "$ROOT"
printf -- "─────────────────────────────────────────────────────\n"
section() { printf "\n${C_BOLD}%s${C_RESET}\n" "$1"; }

# ----- team (best-effort; needs python3 to parse member JSON) -----
TEAM_DIR="$HOME/.claude/teams"
if [[ -d "$TEAM_DIR" && $HAVE_PY -eq 1 ]]; then
  if [[ -n "${MC_TEAM:-}" ]]; then teams=("$TEAM_DIR/$MC_TEAM/config.json"); else teams=("$TEAM_DIR"/*/config.json); fi
  shown=0
  for tf in "${teams[@]}"; do
    [[ -f "$tf" ]] || continue
    mem="$(python3 -c '
import json,sys
try:
    c=json.load(open(sys.argv[1]))
    for m in c.get("members",[]):
        print("    %-22s %s" % (m.get("name","?"), m.get("agentType","") or "-"))
except Exception:
    pass' "$tf" 2>/dev/null || true)"
    if [[ -n "$mem" ]]; then
      [[ $shown -eq 0 ]] && section "Team"
      [[ -z "${MC_TEAM:-}" ]] && printf "  ${C_BLUE}%s${C_RESET}\n" "$(basename "$(dirname "$tf")")"
      printf '%s\n' "$mem"; shown=1
    fi
  done
fi

# ----- task counts per configured state -----
section "Tasks"
for d in $STATES; do
  n="$(find ".claude/tasks/$d" -maxdepth 1 -name '*.md' -type f 2>/dev/null | wc -l | tr -d ' ')"
  ids="$(find ".claude/tasks/$d" -maxdepth 1 -name '*.md' -type f 2>/dev/null | sed 's#.*/##; s/\.md$//' | grep -oE '^[0-9]{4,}' 2>/dev/null | sort -u | tr '\n' ' ' | sed 's/ $//' || true)"
  color="$C_GREY"; warn=""
  case "$d" in
    in-development|decisions|staged) color="$C_AMBER" ;;
    verified|shipped) color="$C_GREEN" ;;
    in-review) color="$C_AMBER"
      if   [[ "${n:-0}" -ge "$CAP" ]];        then warn=" ${C_RED}(at/over cap $CAP!)${C_RESET}"
      elif [[ "${n:-0}" -ge $((CAP-3)) ]];    then warn=" ${C_AMBER}(near cap $CAP)${C_RESET}"; fi ;;
  esac
  printf "  ${color}%-16s${C_RESET} %3d%s" "$d" "${n:-0}" "$warn"
  [[ -n "$ids" ]] && printf "  ${C_DIM}%s${C_RESET}" "$ids"
  echo
done

shopt -s nullglob
# ----- in-development with Track / Estimate -----
indev=(.claude/tasks/in-development/*.md)
if [[ ${#indev[@]} -gt 0 ]]; then
  section "In Development"
  for f in "${indev[@]}"; do
    id="$(basename "$f" .md | grep -oE '^[0-9]{4}')"
    title="$(head -1 "$f" | sed 's/^# *[0-9]* *— *//')"
    track="$(grep -m1 -E '^\*\*Track:\*\*' "$f" | sed 's/^\*\*Track:\*\* *//' || true)"
    est="$(grep -m1 -E '^\*\*Estimate:\*\*' "$f" | sed 's/^\*\*Estimate:\*\* *//' || true)"
    printf "  ${C_AMBER}%s${C_RESET}  %-44s  ${C_DIM}%s${C_RESET}\n" "$id" "${title:0:44}" "${track:+[$track] }$est"
  done
fi

# ----- decisions awaiting -----
dec=(.claude/tasks/decisions/*.md)
if [[ ${#dec[@]} -gt 0 ]]; then
  section "Decisions awaiting"
  for f in "${dec[@]}"; do
    id="$(basename "$f" .md | grep -oE '^[0-9]{4}')"
    title="$(head -1 "$f" | sed 's/^# *[0-9]* *— *//; s/\[DECISION\] *//')"
    printf "  ${C_AMBER}%s${C_RESET}  %s\n" "$id" "$title"
  done
fi

# ----- in-review (cap-aware) -----
inrev=(.claude/tasks/in-review/*.md)
if [[ ${#inrev[@]} -gt 0 ]]; then
  section "In Review"
  printf "  ${C_DIM}cap %d · current %d${C_RESET}\n" "$CAP" "${#inrev[@]}"
  for f in "${inrev[@]}"; do
    id="$(basename "$f" .md | grep -oE '^[0-9]{4}')"
    title="$(head -1 "$f" | sed 's/^# *[0-9]* *— *//')"
    est="$(grep -m1 -E '^\*\*Estimate:\*\*' "$f" | sed 's/^\*\*Estimate:\*\* *//' || true)"
    printf "  ${C_AMBER}%s${C_RESET}  %-44s  ${C_DIM}%s${C_RESET}\n" "$id" "${title:0:44}" "$est"
  done
fi
shopt -u nullglob

# ----- recent commits -----
section "Recent commits"
git -C "$ROOT" log --oneline -5 2>/dev/null | sed 's/^/  /' || true

# ----- build status (config.repos, else scan repos/*) -----
if [[ $SHOW_BUILD -eq 1 ]]; then
  paths=""
  if [[ -f "$CFG" && $HAVE_PY -eq 1 ]]; then
    paths="$(python3 -c '
import json,sys
for r in json.load(open(sys.argv[1])).get("project",{}).get("repos",[]):
    if r.get("path"): print(r["path"])' "$CFG" 2>/dev/null || true)"
  fi
  if [[ -z "$paths" && -d "$ROOT/repos" ]]; then
    for d in "$ROOT"/repos/*; do [[ -d "$d" ]] && paths+="${d#$ROOT/}"$'\n'; done
  fi
  if [[ -n "$paths" ]]; then
    section "Build status"
    while IFS= read -r rp; do
      [[ -n "$rp" ]] || continue
      repo="$ROOT/$rp"; name="$(basename "$rp")"
      if [[ -f "$repo/Cargo.toml" ]]; then
        if (cd "$repo" && cargo check --quiet --message-format=short 2>&1 | grep -qE '(^error|: error)'); then
          printf "  ${C_RED}%-12s${C_RESET} cargo check FAIL\n" "$name"
        else printf "  ${C_GREEN}%-12s${C_RESET} cargo check ok\n" "$name"; fi
      elif [[ -f "$repo/package.json" && -f "$repo/tsconfig.json" ]]; then
        if (cd "$repo" && bunx tsc --noEmit 2>&1 | head -5 | grep -q error); then
          printf "  ${C_RED}%-12s${C_RESET} tsc FAIL\n" "$name"
        else printf "  ${C_GREEN}%-12s${C_RESET} tsc ok\n" "$name"; fi
      fi
    done <<< "$paths"
  fi
fi

# ----- prod health (env override > config.project.prod) -----
if [[ $SHOW_PROD -eq 1 ]]; then
  API="${MC_PROD_API:-}"; WEB="${MC_PROD_WEB:-}"
  if [[ -z "$API$WEB" && -f "$CFG" && $HAVE_PY -eq 1 ]]; then
    API="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("project",{}).get("prod",{}).get("api",""))' "$CFG" 2>/dev/null || true)"
    WEB="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("project",{}).get("prod",{}).get("web",""))' "$CFG" 2>/dev/null || true)"
  fi
  if [[ -n "$API$WEB" ]]; then
    section "Production"
    if [[ -n "$API" ]]; then
      resp="$(curl -s --max-time 3 -w '\nHTTP_%{http_code}' "${API%/}/health" 2>/dev/null || echo 'HTTP_000')"
      code="$(printf '%s' "$resp" | tail -1 | sed 's/HTTP_//')"
      if [[ "$code" == 200 ]]; then printf "  ${C_GREEN}api${C_RESET} %s\n" "$API"
      else printf "  ${C_RED}api${C_RESET} %s ${C_RED}HTTP %s${C_RESET}\n" "$API" "$code"; fi
    fi
    if [[ -n "$WEB" ]]; then
      code="$(curl -sI --max-time 3 "$WEB" 2>/dev/null | head -1 | grep -oE '[0-9]{3}' | head -1 || true)"
      if [[ "$code" == 200 ]]; then printf "  ${C_GREEN}web${C_RESET} %s\n" "$WEB"
      else printf "  ${C_RED}web${C_RESET} %s ${C_RED}HTTP %s${C_RESET}\n" "$WEB" "${code:-000}"; fi
    fi
  fi
fi

# ----- footer -----
section "Next"
[[ -f "$ROOT/.claude/tasks/_next-id" ]] && printf "  ${C_DIM}next-id: %s${C_RESET}\n" "$(tr -d ' \n' < "$ROOT/.claude/tasks/_next-id")"
printf "\n"
exit 0
