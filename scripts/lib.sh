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
# IL_LOCK_TTL (default 60s) is stale — the holder died — and is reclaimed in
# two steps: (1) CAPTURE the current incarnation by atomic rename — rename(2)
# succeeds for exactly one contender, so two contenders can never both reclaim
# the same incarnation (a bare `rm -f` let both delete and both claim — a
# reproduced mutual-exclusion violation); (2) RE-JUDGE the captured file —
# between the staleness read and the mv another contender may have completed
# a reclaim and a LIVE lock may have taken the path, in which case the capture
# is restored via hard link (atomic, never clobbers a newer claim) instead of
# discarded. Only a capture that is stale on re-judgment is discarded.
# Each claim embeds a unique token so il_unlock only removes a lock this
# process still owns — never a later holder's lock after a stale reclaim.
# Where flock(1) exists (Linux), the whole observe→decide→act sequence above
# additionally serializes on fd 209 over <name>.lock.flock — the kernel
# releases it if the holder dies, and it closes the read-then-act windows
# COMPLETELY among il_lock users. The heartbeat-file protocol is unchanged, so
# foreign writers (coord's with-lock.sh) still interoperate; without flock
# (macOS) the atomic primitives above leave only a microsecond-scale window.
# Waits up to IL_LOCK_WAIT seconds (default 10) for a fresh lock to clear,
# then fails with 75 (EX_TEMPFAIL): the caller should skip, not crash.
# Released by il_unlock, installed on EXIT (and INT/TERM route through EXIT).
# heartbeat_epoch is stamped once at claim time; a critical section expected to
# run anywhere near IL_LOCK_TTL must call il_lock_refresh periodically or its
# lock will be treated as abandoned. Current sections (evolve check/log,
# task-new id bump) finish in well under a second, so no caller refreshes yet.
IL_LOCK_FILE=""
IL_LOCK_TOKEN=""
IL_LOCK_FLOCK=0
il_lock() { # <project_root> <name>
  local root="$1" name="$2" dir lock now hb waited=0 token claim line ws hb2
  dir="$root/.claude/locks"
  mkdir -p "$dir" 2>/dev/null || { echo "il_lock: cannot create $dir" >&2; return 1; }
  lock="$dir/$name.lock"
  # PID alone recycles across processes — add a nonce so ownership is unambiguous
  token="$$-$(date +%s%N 2>/dev/null || date +%s)-$RANDOM"
  IL_LOCK_FLOCK=0
  if command -v flock >/dev/null 2>&1 && exec 209>>"$lock.flock" 2>/dev/null; then
    IL_LOCK_FLOCK=1
  fi
  while :; do
    # hold flock only across one observe→decide→act iteration, never across a
    # sleep or the caller's critical section — the heartbeat FILE is the lock;
    # flock just makes each contender's decision about it atomic
    [ "$IL_LOCK_FLOCK" = 1 ] && flock 209 2>/dev/null || true
    if ( set -o noclobber; printf '{"name":"%s","holder":"pid-%s@%s","pid":%s,"heartbeat_epoch":%s,"action":"%s","token":"%s"}\n' \
          "$name" "$$" "${HOSTNAME:-host}" "$$" "$(date +%s)" "${0##*/}" "$token" > "$lock" ) 2>/dev/null; then
      IL_LOCK_FILE="$lock"
      IL_LOCK_TOKEN="$token"
      trap 'il_unlock' EXIT
      trap 'exit 130' INT
      trap 'exit 143' TERM
      [ "$IL_LOCK_FLOCK" = 1 ] && flock -u 209 2>/dev/null || true
      return 0
    fi
    hb="$(sed -n 's/.*"heartbeat_epoch":[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$lock" 2>/dev/null | head -1 || true)"
    # unreadable/mid-write lock: judge freshness by file mtime instead
    if [ -z "$hb" ]; then
      hb="$(stat -c %Y "$lock" 2>/dev/null || stat -f %m "$lock" 2>/dev/null || echo 0)"
    fi
    now="$(date +%s)"
    if [ $(( now - hb )) -le "${IL_LOCK_TTL:-60}" ]; then
      [ "$IL_LOCK_FLOCK" = 1 ] && flock -u 209 2>/dev/null || true
      if [ "$waited" -ge "${IL_LOCK_WAIT:-10}" ]; then
        echo "il_lock: '$name' is held by another session (heartbeat $(( now - hb ))s ago, $lock) — try again shortly" >&2
        return 75
      fi
      sleep 1; waited=$(( waited + 1 ))
    else
      # stale (holder died) — CAPTURE the current incarnation by atomic rename;
      # at most one contender can capture a given incarnation. A contender
      # whose mv fails loops back and re-checks — it must NOT assume the path
      # is now free.
      claim="$lock.reclaim.$$"
      if mv "$lock" "$claim" 2>/dev/null; then
        # RE-JUDGE what we actually captured: between our staleness read and
        # the mv, another contender may have finished a reclaim and a LIVE
        # lock may have taken the path — then we just captured a live lock and
        # must put it back, not kill it. Parse with bash builtins only: the
        # lock path must stay empty for as short a window as possible.
        line=""; hb2=""
        IFS= read -r line < "$claim" 2>/dev/null || true
        case "$line" in *'"heartbeat_epoch":'*)
          hb2="${line#*\"heartbeat_epoch\":}"
          ws="${hb2%%[0-9]*}"   # prefix before the first digit — must be blank
          case "$ws" in
            *[![:space:]]*) hb2="" ;;
            *) hb2="${hb2#"$ws"}"; hb2="${hb2%%[!0-9]*}" ;;
          esac ;;
        esac
        [ -n "$hb2" ] || hb2="$(stat -c %Y "$claim" 2>/dev/null || stat -f %m "$claim" 2>/dev/null || echo 0)"
        if [ $(( now - hb2 )) -le "${IL_LOCK_TTL:-60}" ]; then
          # live lock captured by mistake — restore it. Hard link creation is
          # atomic and FAILS if a new claim appeared meanwhile, so the restore
          # can never clobber anyone; then drop our extra name for the inode.
          ln "$claim" "$lock" 2>/dev/null || true
          rm -f "$claim" 2>/dev/null || true
        else
          rm -f "$claim" 2>/dev/null || true   # genuinely dead — discard, then retry the create
        fi
      fi
      [ "$IL_LOCK_FLOCK" = 1 ] && flock -u 209 2>/dev/null || true
    fi
  done
}
il_unlock() {
  # only remove a lock we still own: after a stale reclaim the path may hold a
  # LATER session's lock, and deleting that would let a third contender in
  [ "${IL_LOCK_FLOCK:-0}" = 1 ] && flock 209 2>/dev/null || true
  if [ -n "${IL_LOCK_FILE:-}" ] && [ -f "$IL_LOCK_FILE" ] \
     && grep -qF "\"token\":\"${IL_LOCK_TOKEN}\"" "$IL_LOCK_FILE" 2>/dev/null; then
    rm -f "$IL_LOCK_FILE" 2>/dev/null
  fi
  if [ "${IL_LOCK_FLOCK:-0}" = 1 ]; then
    flock -u 209 2>/dev/null || true
    exec 209>&- 2>/dev/null || true
  fi
  IL_LOCK_FLOCK=0
  IL_LOCK_FILE=""
  IL_LOCK_TOKEN=""
  return 0
}
# il_lock_refresh — re-stamp heartbeat_epoch on the held lock so a legitimately
# long critical section is not mistaken for an abandoned one and reclaimed.
# No-op if we no longer own the lock. Call every < IL_LOCK_TTL/2 seconds from
# inside sections that can run long (none do today — see the note on il_lock).
il_lock_refresh() {
  local tmp
  [ -n "${IL_LOCK_FILE:-}" ] && [ -f "$IL_LOCK_FILE" ] || return 0
  [ "${IL_LOCK_FLOCK:-0}" = 1 ] && flock 209 2>/dev/null || true
  tmp="$IL_LOCK_FILE.hb.$$"
  if grep -qF "\"token\":\"${IL_LOCK_TOKEN}\"" "$IL_LOCK_FILE" 2>/dev/null \
     && sed "s/\"heartbeat_epoch\":[[:space:]]*[0-9]*/\"heartbeat_epoch\":$(date +%s)/" \
          "$IL_LOCK_FILE" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$IL_LOCK_FILE" 2>/dev/null || rm -f "$tmp" 2>/dev/null
  else
    rm -f "$tmp" 2>/dev/null
  fi
  [ "${IL_LOCK_FLOCK:-0}" = 1 ] && flock -u 209 2>/dev/null || true
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
