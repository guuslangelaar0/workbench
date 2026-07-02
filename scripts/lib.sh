#!/usr/bin/env bash
# Shared helpers for workbench scripts. No jq dependency.

# Resolve the workbench config dir for a project root: prefer .workbench/,
# fall back to a legacy .initlab/ so adopted projects keep working pre-migration.
il_cfg_dir() { # <project_root>
  if [ -d "$1/.workbench" ]; then printf '%s\n' "$1/.workbench"
  elif [ -d "$1/.initlab" ]; then printf '%s\n' "$1/.initlab"
  else printf '%s\n' "$1/.workbench"; fi
}

# Resolve a project root from a launch directory. Claude hooks may start from a
# repo subdirectory, but Workbench state belongs to the nearest configured root.
il_project_root() { # <path>
  local p="${1:-$PWD}" cur parent
  [ -n "$p" ] || p="$PWD"
  [ -f "$p" ] && p="$(dirname "$p")"

  if cur="$(cd "$p" 2>/dev/null && pwd -P)"; then
    while :; do
      if [ -f "$cur/.workbench/config.json" ] || [ -f "$cur/.initlab/config.json" ]; then
        printf '%s\n' "$cur"
        return 0
      fi
      [ "$cur" = "/" ] && break
      parent="$(dirname "$cur")"
      [ "$parent" = "$cur" ] && break
      cur="$parent"
    done
  fi

  printf '%s\n' "$p"
}

# True when Workbench hooks should run for this project. Missing hook preference
# is treated as enabled for backward compatibility with pre-hook-choice configs.
il_hooks_enabled() { # <project_root>
  local cfg="$1"
  cfg="$(il_cfg_dir "$cfg")/config.json"
  [ -f "$cfg" ] || return 1
  awk '
    /"hooks"[[:space:]]*:/ { in_hooks=1 }
    in_hooks && /"mode"[[:space:]]*:[[:space:]]*"disabled"/ { disabled=1 }
    in_hooks && /\}/ { in_hooks=0 }
    END { exit disabled ? 1 : 0 }
  ' "$cfg" 2>/dev/null
}

# sha256 of a file -> bare hex. Works on Linux (sha256sum) and macOS (shasum).
il_hash() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}';
  else shasum -a 256 "$1" | awk '{print $1}'; fi
}

# Escape a string for safe inclusion as a JSON string value (handles \ and ").
il_json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"   # backslash first
  s="${s//\"/\\\"}"   # then double-quote
  s="${s//$'\n'/\\n}"   # newline
  s="${s//$'\t'/\\t}"   # tab
  printf '%s' "$s"
}

# --- advisory lock --------------------------------------------------------------
# il_lock <project_root> <name> — serialize a read-modify-write sequence across
# concurrent sessions on this machine (same class of problem the coord tooling's
# scripts/coord/with-lock.sh solves for deploys; same lock location and JSON shape
# — a heartbeat_epoch-bearing file at .claude/locks/<name>.lock — so the two
# disciplines respect each other's locks).
#
# Claim is atomic (noclobber create). A lock whose heartbeat is older than
# IL_LOCK_TTL (default 60s) is stale — the holder died — and is reclaimed.
# Waits up to IL_LOCK_WAIT seconds (default 10) for a fresh lock to clear,
# then fails with 75 (EX_TEMPFAIL): the caller should skip, not crash.
# Released by il_unlock, installed on EXIT (and INT/TERM route through EXIT).
IL_LOCK_FILE=""
il_lock() { # <project_root> <name>
  local root="$1" name="$2" dir lock now hb waited=0
  dir="$root/.claude/locks"
  mkdir -p "$dir" 2>/dev/null || { echo "il_lock: cannot create $dir" >&2; return 1; }
  lock="$dir/$name.lock"
  while :; do
    if ( set -o noclobber; printf '{"name":"%s","holder":"pid-%s@%s","pid":%s,"heartbeat_epoch":%s,"action":"%s"}\n' \
          "$name" "$$" "${HOSTNAME:-host}" "$$" "$(date +%s)" "${0##*/}" > "$lock" ) 2>/dev/null; then
      IL_LOCK_FILE="$lock"
      trap 'il_unlock' EXIT
      trap 'exit 130' INT
      trap 'exit 143' TERM
      return 0
    fi
    hb="$(sed -n 's/.*"heartbeat_epoch":[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$lock" 2>/dev/null | head -1 || true)"
    # unreadable/mid-write lock: judge freshness by file mtime instead
    if [ -z "$hb" ]; then
      hb="$(stat -c %Y "$lock" 2>/dev/null || stat -f %m "$lock" 2>/dev/null || echo 0)"
    fi
    now="$(date +%s)"
    if [ $(( now - hb )) -le "${IL_LOCK_TTL:-60}" ]; then
      if [ "$waited" -ge "${IL_LOCK_WAIT:-10}" ]; then
        echo "il_lock: '$name' is held by another session (heartbeat $(( now - hb ))s ago, $lock) — try again shortly" >&2
        return 75
      fi
      sleep 1; waited=$(( waited + 1 ))
    else
      rm -f "$lock" 2>/dev/null || true   # stale (holder died) — reclaim and retry
    fi
  done
}
il_unlock() {
  [ -n "${IL_LOCK_FILE:-}" ] && rm -f "$IL_LOCK_FILE" 2>/dev/null
  IL_LOCK_FILE=""
  return 0
}

# Render a .tmpl file by substituting {{KEY}} tokens. Args: <tmpl> <out> then KEY=VALUE pairs.
# Two-phase (template tokens -> sentinels -> values) so a value that itself contains a
# {{KEY}} substring is never re-scanned and clobbered. Values may contain any chars (incl. &, \).
il_render() {
  local tmpl="$1" out="$2"; shift 2
  local content pair k v
  local S1=$'\x01' S2=$'\x02'
  # bash 5.2+ defaults `patsub_replacement` ON, which makes `&` in a ${//} replacement
  # expand to the MATCHED text (sed-like) — that would corrupt any value containing `&`.
  # Disable it for the duration (scoped save/restore) so replacement is purely literal;
  # then values containing `&`, `\`, etc. need no escaping. No-op on bash < 5.2.
  local _patsub; _patsub="$(shopt -p patsub_replacement 2>/dev/null || true)"
  shopt -u patsub_replacement 2>/dev/null || true
  content="$(cat "$tmpl")"
  # phase 1: replace each template {{KEY}} with a unique sentinel (no user values yet)
  for pair in "$@"; do
    k="${pair%%=*}"
    content="${content//\{\{$k\}\}/$S1$k$S2}"
  done
  # phase 2: replace sentinels with values, literally (values are not re-scanned for tokens)
  for pair in "$@"; do
    k="${pair%%=*}"; v="${pair#*=}"
    content="${content//$S1$k$S2/$v}"
  done
  [ -n "$_patsub" ] && eval "$_patsub" 2>/dev/null || true   # restore prior shopt state
  printf '%s\n' "$content" > "$out"
}
