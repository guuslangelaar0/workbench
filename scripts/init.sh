#!/usr/bin/env bash
# workbench scaffolder. Deterministic; the interactive wizard
# (/workbench:setup) is layered on top.
#
# Usage: init.sh --name <NAME> [--mission <M>] [--launch <L>] [--target <DIR>]
set -euo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # workbench/scripts
PLUGIN_ROOT="$(cd "$SELF_DIR/.." && pwd)"                  # workbench
. "$SELF_DIR/lib.sh"
. "$SELF_DIR/levels.sh"

NAME="" MISSION="" LAUNCH="" TARGET="$PWD" PROFILE="full" LEVEL=""
need_arg() { [ "$#" -ge 2 ] || { echo "init.sh: $1 requires a value" >&2; exit 64; }; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --name)    need_arg "$@"; NAME="$2"; shift 2 ;;
    --mission) need_arg "$@"; MISSION="$2"; shift 2 ;;
    --launch)  need_arg "$@"; LAUNCH="$2"; shift 2 ;;
    --target)  need_arg "$@"; TARGET="$2"; shift 2 ;;
    --profile) need_arg "$@"; PROFILE="$2"; shift 2 ;;
    --level)   need_arg "$@"; LEVEL="$2"; shift 2 ;;
    *) echo "init.sh: unknown arg '$1'" >&2; exit 64 ;;
  esac
done
[ -n "$NAME" ] || { echo "init.sh: --name is required" >&2; exit 64; }
[ -n "$MISSION" ] || MISSION="(mission not set)"
[ -n "$LAUNCH" ]  || LAUNCH="(no target date)"
case "$PROFILE" in minimal|full) ;; *) echo "init.sh: --profile must be minimal|full" >&2; exit 64 ;; esac
# default level: fleet for full profile, solo for minimal
[ -n "$LEVEL" ] || { [ "$PROFILE" = full ] && LEVEL="fleet" || LEVEL="solo"; }
wb_level_index "$LEVEL" >/dev/null || { echo "init.sh: --level must be solo|pair|crew|fleet" >&2; exit 64; }

VERSION="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$PLUGIN_ROOT/.claude-plugin/plugin.json" | head -1)"
[ -n "$VERSION" ] || { echo "init.sh: could not read plugin version from plugin.json" >&2; exit 1; }
TMPL_MIN="$PLUGIN_ROOT/templates/minimal"
TMPL_FULL="$PLUGIN_ROOT/templates/full"
TMPL_COORD="$PLUGIN_ROOT/templates/coord"
TMPL_CODEX="$PLUGIN_ROOT/templates/codex"

# init is a GREENFIELD scaffold: it must never overwrite a file that already
# exists (the user's CLAUDE.md, edited coord scripts, etc.). Existing files are
# preserved and reported; /workbench:upgrade is the path that reconciles them
# against current templates. PRESERVED accumulates the relpaths we left alone.
PRESERVED=""
note_preserved() { PRESERVED="${PRESERVED:+$PRESERVED }$1"; }
render_new() { # <tmpl> <dest> <relpath> [tokens...]
  local tmpl="$1" dest="$2" rel="$3"; shift 3
  if [ -e "$dest" ]; then note_preserved "$rel"; else il_render "$tmpl" "$dest" "$@"; fi
}
copy_new() { # <src> <dest> <relpath>
  if [ -e "$2" ]; then note_preserved "$3"; else cp "$1" "$2"; fi
}

# 1. task lifecycle dirs — driven by level
for d in $(wb_level_lifecycle "$LEVEL"); do
  mkdir -p "$TARGET/.claude/tasks/$d"
done
# 2. task README (merge) + _next-id (once) — never clobber existing
copy_new "$TMPL_MIN/tasks/README.md" "$TARGET/.claude/tasks/README.md" ".claude/tasks/README.md"
copy_new "$TMPL_MIN/tasks/_next-id"  "$TARGET/.claude/tasks/_next-id"  ".claude/tasks/_next-id"
# 3. render the profile's docs
if [ "$PROFILE" = full ]; then
  mkdir -p "$TARGET/.claude" "$TARGET/scripts/coord"
  render_new "$TMPL_FULL/CLAUDE.md.tmpl" "$TARGET/CLAUDE.md" "CLAUDE.md" \
    "PROJECT_NAME=$NAME" "MISSION=$MISSION" "LAUNCH=$LAUNCH" "REPO_MAP=${REPO_MAP:-(single repo)}"
  render_new "$TMPL_FULL/SOUL.md.tmpl"   "$TARGET/.claude/SOUL.md" ".claude/SOUL.md" "PROJECT_NAME=$NAME" "MISSION=$MISSION"
  render_new "$TMPL_FULL/AGENTS.md.tmpl" "$TARGET/AGENTS.md" "AGENTS.md" "PROJECT_NAME=$NAME"
  for s in lib.sh wb-coord with-lock.sh precommit-guard.sh bb-worktree.sh install-hooks.sh; do
    copy_new "$TMPL_COORD/$s" "$TARGET/scripts/coord/$s" "scripts/coord/$s"
  done
  chmod +x "$TARGET/scripts/coord/wb-coord" 2>/dev/null || true
  # coordination runtime state (heartbeats, locks) must never be committed (idempotent)
  GI="$TARGET/.gitignore"
  if ! { [ -f "$GI" ] && grep -qxF '/.claude/locks/' "$GI"; }; then
    printf '\n# workbench coordination runtime state (heartbeats, locks) — never commit\n/.claude/locks/\n' >> "$GI"
  fi
  render_new "$TMPL_FULL/SESSION_STATE.md.tmpl" "$TARGET/.claude/SESSION_STATE.md" ".claude/SESSION_STATE.md" "PROJECT_NAME=$NAME"
else
  render_new "$TMPL_MIN/CLAUDE.md.tmpl" "$TARGET/CLAUDE.md" "CLAUDE.md" \
    "PROJECT_NAME=$NAME" "MISSION=$MISSION" "LAUNCH=$LAUNCH"
fi

# 3b. codex bridge: render only when enabled in an existing config (the wizard sets this)
CODEX="off"
_cfg="$(il_cfg_dir "$TARGET")/config.json"
[ -f "$_cfg" ] && CODEX="$(sed -n 's/.*"codex"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$_cfg" | head -1)"
if [ "$PROFILE" = full ] && [ -n "$CODEX" ] && [ "$CODEX" != off ]; then
  render_new "$TMPL_CODEX/CODEX_COORDINATION.md.tmpl" "$TARGET/.claude/CODEX_COORDINATION.md" ".claude/CODEX_COORDINATION.md" "PROJECT_NAME=$NAME"
  render_new "$TMPL_CODEX/codex-teamlead-prompt.md.tmpl" "$TARGET/.claude/codex-teamlead-prompt.md" ".claude/codex-teamlead-prompt.md" "PROJECT_NAME=$NAME"
fi

# 4. .workbench/config.json
mkdir -p "$TARGET/.workbench"
if [ ! -f "$TARGET/.workbench/config.json" ]; then
  NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  # Build dials JSON block from level presets (sed-based, jq-free)
  DIALS_JSON="$(wb_level_dials "$LEVEL" | sed 's/^\([^=]*\)=\(.*\)$/    "\1": "\2",/' | sed '$ s/,$//')"
  # Build lifecycle states array from level (exclude decisions from the states array)
  STATES_JSON="$(wb_level_lifecycle "$LEVEL" | tr ' ' '\n' | grep -v '^decisions$' | sed 's/.*/"&"/' | tr '\n' ',' | sed 's/,$//')"
  # deploy_gated is true for crew and fleet
  case "$LEVEL" in
    crew|fleet) DEPLOY_GATED=true ;;
    *)          DEPLOY_GATED=false ;;
  esac
  cat > "$TARGET/.workbench/config.json" <<JSON
{
  "workbench": { "version": "$VERSION", "initialized_at": "$NOW", "level": "$LEVEL" },
  "project": {
    "name": "$(il_json_escape "$NAME")",
    "mission": "$(il_json_escape "$MISSION")",
    "launch_target": "$(il_json_escape "$LAUNCH")",
    "kind": "existing",
    "topology": "single",
    "repos": [],
    "prod": {}
  },
  "way_of_working": {
    "models": "recommended",
    "verification": "recommended",
    "review": "recommended",
    "parallelism": "recommended",
    "enforcement": "warn-default",
    "continuity": "recommended",
    "graphify": "off",
    "codex": "off",
    "remote": "off",
    "inception_depth": "recommended"
  },
  "dials": {
$DIALS_JSON
  },
  "lifecycle": {
    "states": [$STATES_JSON],
    "deploy_gated": $DEPLOY_GATED,
    "in_review_cap": 10
  }
}
JSON
fi

# 5. .workbench/manifest.json — record managed files with hashes + modes (jq-free accumulator)
MANIFEST_ENTRIES=""
add_manifest() { # <path> <template> <mode>
  local h; h="sha256:$(il_hash "$TARGET/$1")"
  local rec="{ \"path\": \"$1\", \"template\": \"$2\", \"mode\": \"$3\", \"rendered_hash\": \"$h\", \"from_version\": \"$VERSION\" }"
  MANIFEST_ENTRIES="${MANIFEST_ENTRIES:+$MANIFEST_ENTRIES,}$rec"
}
add_manifest "CLAUDE.md" "$( [ "$PROFILE" = full ] && echo full/CLAUDE.md.tmpl || echo minimal/CLAUDE.md.tmpl )" "merge"
add_manifest ".claude/tasks/README.md" "minimal/tasks/README.md" "merge"
if [ "$PROFILE" = full ]; then
  add_manifest ".claude/SOUL.md" "full/SOUL.md.tmpl" "merge"
  add_manifest "AGENTS.md" "full/AGENTS.md.tmpl" "merge"
  for s in lib.sh wb-coord with-lock.sh precommit-guard.sh bb-worktree.sh install-hooks.sh; do
    add_manifest "scripts/coord/$s" "coord/$s" "managed"
  done
  [ -f "$TARGET/.claude/SESSION_STATE.md" ] && add_manifest ".claude/SESSION_STATE.md" "full/SESSION_STATE.md.tmpl" "once"
fi
add_manifest ".claude/tasks/_next-id" "minimal/tasks/_next-id" "once"
# codex bridge manifest entries (only when codex was rendered above)
if [ "$PROFILE" = full ] && [ -n "$CODEX" ] && [ "$CODEX" != off ]; then
  add_manifest ".claude/CODEX_COORDINATION.md" "codex/CODEX_COORDINATION.md.tmpl" "merge"
  add_manifest ".claude/codex-teamlead-prompt.md" "codex/codex-teamlead-prompt.md.tmpl" "managed"
fi
cat > "$TARGET/.workbench/manifest.json" <<JSON
{
  "plugin_version": "$VERSION",
  "files": [ $MANIFEST_ENTRIES ]
}
JSON

# 6. install the git pre-commit guard (full profile, if target is a git repo)
if [ "$PROFILE" = full ] && [ -d "$TARGET/.git" ]; then
  bash "$TARGET/scripts/coord/install-hooks.sh" "$TARGET" >/dev/null || echo "init.sh: warning — pre-commit guard install reported an issue" >&2
fi

echo "workbench: scaffolded '$NAME' ($PROFILE) into $TARGET"
echo "  .claude/tasks/{backlog,in-development,in-review,verified,decisions}/"
echo "  CLAUDE.md, .workbench/config.json, .workbench/manifest.json"
if [ -n "$PRESERVED" ]; then
  echo "  preserved (already existed, not overwritten): $PRESERVED"
  echo "  → run /workbench:upgrade to reconcile preserved files against the current templates."
fi
