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

NAME="" MISSION="" LAUNCH="" TARGET="$PWD" PROFILE="full" LEVEL="" LEVEL_EXPLICIT=0
need_arg() { [ "$#" -ge 2 ] || { echo "init.sh: $1 requires a value" >&2; exit 64; }; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --name)    need_arg "$@"; NAME="$2"; shift 2 ;;
    --mission) need_arg "$@"; MISSION="$2"; shift 2 ;;
    --launch)  need_arg "$@"; LAUNCH="$2"; shift 2 ;;
    --target)  need_arg "$@"; TARGET="$2"; shift 2 ;;
    --profile) need_arg "$@"; PROFILE="$2"; shift 2 ;;
    --level)   need_arg "$@"; LEVEL="$2"; LEVEL_EXPLICIT=1; shift 2 ;;
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
was_preserved() { case " $PRESERVED " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }
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
# 1b. epics dir — only for levels whose decomposition is grouped (pair/crew/fleet);
# solo uses flat tasks (decomposition=tasks) and gets no epics dir.
_dec="$(wb_level_dials "$LEVEL" | sed -n 's/^decomposition=//p')"
[ -n "$_dec" ] && [ "$_dec" != tasks ] && mkdir -p "$TARGET/.claude/epics"
GI="$TARGET/.gitignore"
MESH_GITIGNORE_ACTION="already-present"
if ! { [ -f "$GI" ] && grep -qxF '/.workbench/mesh/' "$GI"; }; then
  printf '\n# workbench mesh runtime state — never commit\n/.workbench/mesh/\n' >> "$GI"
  MESH_GITIGNORE_ACTION="appended"
fi
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
  GITIGNORE_ACTION="already-present"
  if ! { [ -f "$GI" ] && grep -qxF '/.claude/locks/' "$GI"; }; then
    printf '\n# workbench coordination runtime state (heartbeats, locks) — never commit\n/.claude/locks/\n' >> "$GI"
    GITIGNORE_ACTION="appended"
  fi
  render_new "$TMPL_FULL/SESSION_STATE.md.tmpl" "$TARGET/.claude/SESSION_STATE.md" ".claude/SESSION_STATE.md" "PROJECT_NAME=$NAME"
  # durable loop charter — the stable north star, re-injected at SessionStart + kept across compaction
  mkdir -p "$TARGET/.workbench"
  render_new "$TMPL_FULL/loop-charter.md.tmpl" "$TARGET/.workbench/loop-charter.md" ".workbench/loop-charter.md" "PROJECT_NAME=$NAME" "MISSION=$MISSION"
  # context backbone (C4 authored-intent docs) — scaled to the architecture dial.
  # Cumulative: context → +containers → +components. none (solo) gets nothing.
  _arch="$(wb_level_dials "$LEVEL" | sed -n 's/^architecture=//p')"
  if [ -n "$_arch" ] && [ "$_arch" != none ]; then
    mkdir -p "$TARGET/.claude/architecture"
    render_new "$TMPL_FULL/architecture/context.md.tmpl" "$TARGET/.claude/architecture/context.md" ".claude/architecture/context.md" "PROJECT_NAME=$NAME"
    case "$_arch" in
      containers|components)
        render_new "$TMPL_FULL/architecture/containers.md.tmpl" "$TARGET/.claude/architecture/containers.md" ".claude/architecture/containers.md" "PROJECT_NAME=$NAME" ;;
    esac
    case "$_arch" in
      components)
        render_new "$TMPL_FULL/architecture/components.md.tmpl" "$TARGET/.claude/architecture/components.md" ".claude/architecture/components.md" "PROJECT_NAME=$NAME" ;;
    esac
  fi
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
CFG="$TARGET/.workbench/config.json"
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
if [ ! -f "$CFG" ]; then
  cat > "$CFG" <<JSON
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
    "cross_model_verification": "off",
    "review": "recommended",
    "parallelism": "recommended",
    "enforcement": "warn-default",
    "continuity": "recommended",
    "graphify": "off",
    "codex": "off",
    "remote": "off",
    "inception_depth": "recommended"
  },
  "dial_overrides": {},
  "lifecycle": { "in_review_cap": 10 }
}
JSON
elif [ "$LEVEL_EXPLICIT" = 1 ]; then
  # Existing config + explicit --level: upsert the level scalar within the
  # workbench object ONLY; every other field is preserved byte-for-byte.
  # Done with POSIX awk (portable, no gawk-only features, no `sed -i` flavor
  # differences) so it is correct for single- AND multi-line layouts and never
  # touches a stray "level" key in some other object (e.g. a logging config).
  # The workbench object is flat (scalar fields), so its first `}` closes it.
  awk -v lvl="$LEVEL" '
    done { print; next }
    !inwb && /"workbench"[[:space:]]*:/ { inwb=1 }
    inwb {
      p = index($0, "}")                # workbench is flat, so its first } closes it
      if (p > 0) {                       # workbench closes on this line
        head = substr($0, 1, p-1); tail = substr($0, p)
        if (head ~ /"level"[[:space:]]*:[[:space:]]*"[^"]*"/)
          sub(/"level"[[:space:]]*:[[:space:]]*"[^"]*"/, "\"level\": \"" lvl "\"", head)
        else
          head = head ", \"level\": \"" lvl "\" "   # inject before the closing brace
        print head tail; done=1; next
      }
      if (/"level"[[:space:]]*:[[:space:]]*"[^"]*"/) {   # level on its own line inside workbench
        sub(/"level"[[:space:]]*:[[:space:]]*"[^"]*"/, "\"level\": \"" lvl "\""); done=1; print; next
      }
      print; next
    }
    { print }
  ' "$CFG" > "$CFG.tmp" && mv "$CFG.tmp" "$CFG"
fi

# 5. .workbench/manifest.json — install ledger with hashes, ownership, and side effects.
# init is greenfield-only: if a manifest already exists, leave it as the source of truth.
if [ ! -f "$TARGET/.workbench/manifest.json" ]; then
  MANIFEST_ENTRIES=""
  json_hash_or_null() { [ -f "$1" ] && printf '"sha256:%s"' "$(il_hash "$1")" || printf 'null'; }
  add_manifest() { # <path> <template> <mode>
    local path="$1" template="$2" mode="$3"
    local file="$TARGET/$path" tmpl="$PLUGIN_ROOT/templates/$template"
    [ -f "$file" ] || return 0
    local rendered_hash template_hash action preexisting previous_hash
    rendered_hash="sha256:$(il_hash "$file")"
    template_hash="$(json_hash_or_null "$tmpl")"
    if was_preserved "$path"; then
      action="preserved"; preexisting=true; previous_hash="\"$rendered_hash\""
    else
      action="created"; preexisting=false; previous_hash=null
    fi
    local rec="{ \"path\": \"$path\", \"template\": \"$template\", \"mode\": \"$mode\", \"action\": \"$action\", \"preexisting\": $preexisting, \"previous_hash\": $previous_hash, \"rendered_hash\": \"$rendered_hash\", \"template_hash\": $template_hash, \"from_version\": \"$VERSION\" }"
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
    add_manifest ".claude/SESSION_STATE.md" "full/SESSION_STATE.md.tmpl" "once"
    add_manifest ".workbench/loop-charter.md" "full/loop-charter.md.tmpl" "once"
    add_manifest ".claude/architecture/context.md" "full/architecture/context.md.tmpl" "merge"
    add_manifest ".claude/architecture/containers.md" "full/architecture/containers.md.tmpl" "merge"
    add_manifest ".claude/architecture/components.md" "full/architecture/components.md.tmpl" "merge"
  fi
  add_manifest ".claude/tasks/_next-id" "minimal/tasks/_next-id" "once"
  # codex bridge manifest entries (only when codex was rendered above)
  if [ "$PROFILE" = full ] && [ -n "$CODEX" ] && [ "$CODEX" != off ]; then
    add_manifest ".claude/CODEX_COORDINATION.md" "codex/CODEX_COORDINATION.md.tmpl" "merge"
    add_manifest ".claude/codex-teamlead-prompt.md" "codex/codex-teamlead-prompt.md.tmpl" "managed"
  fi

  CREATED_DIRS='".workbench"'
  for d in $(wb_level_lifecycle "$LEVEL"); do
    CREATED_DIRS="$CREATED_DIRS, \".claude/tasks/$d\""
  done
  [ -d "$TARGET/.claude/epics" ] && CREATED_DIRS="$CREATED_DIRS, \".claude/epics\""
  if [ "$PROFILE" = full ]; then
    CREATED_DIRS="$CREATED_DIRS, \".claude\", \"scripts/coord\""
    [ -d "$TARGET/.claude/architecture" ] && CREATED_DIRS="$CREATED_DIRS, \".claude/architecture\""
  fi
  GITIGNORE_BLOCKS=""
  GIT_HOOKS=""
  GITIGNORE_BLOCKS="{ \"path\": \".gitignore\", \"marker\": \"workbench mesh runtime state\", \"lines\": [\"/.workbench/mesh/\"], \"action\": \"${MESH_GITIGNORE_ACTION:-already-present}\" }"
  if [ "$PROFILE" = full ]; then
    GITIGNORE_BLOCKS="$GITIGNORE_BLOCKS, { \"path\": \".gitignore\", \"marker\": \"workbench coordination runtime state\", \"lines\": [\"/.claude/locks/\"], \"action\": \"${GITIGNORE_ACTION:-already-present}\" }"
    if [ -d "$TARGET/.git" ]; then
      GIT_HOOKS="{ \"type\": \"pre-commit\", \"path\": \".git/hooks/pre-commit\", \"marker\": \"wb-coord commit guard (B)\", \"action\": \"installed\" }"
    fi
  fi
  cat > "$TARGET/.workbench/manifest.json" <<JSON
{
  "schema_version": 2,
  "plugin_version": "$VERSION",
  "plugin": {
    "name": "workbench",
    "version": "$VERSION",
    "source": "workbench@workbench",
    "installed_at": "$NOW"
  },
  "files": [ $MANIFEST_ENTRIES ],
  "side_effects": {
    "gitignore_blocks": [ $GITIGNORE_BLOCKS ],
    "git_hooks": [ $GIT_HOOKS ],
    "created_dirs": [ $CREATED_DIRS ],
    "runtime_dirs": [ ".claude/locks", ".workbench/checkpoints", ".workbench/lanes" ]
  }
}
JSON
fi

# 6. install the git pre-commit guard (full profile, if target is a git repo)
if [ "$PROFILE" = full ] && [ -d "$TARGET/.git" ]; then
  bash "$TARGET/scripts/coord/install-hooks.sh" "$TARGET" >/dev/null || echo "init.sh: warning — pre-commit guard install reported an issue" >&2
fi

echo "workbench: scaffolded '$NAME' ($PROFILE, level $LEVEL) into $TARGET"
echo "  .claude/tasks/: $(wb_level_lifecycle "$LEVEL" | tr ' ' ',')"
echo "  CLAUDE.md, .workbench/config.json, .workbench/manifest.json"
if [ -n "$PRESERVED" ]; then
  echo "  preserved (already existed, not overwritten): $PRESERVED"
  echo "  → run /workbench:upgrade to reconcile preserved files against the current templates."
fi
