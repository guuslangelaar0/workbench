#!/usr/bin/env bash
# Shared helpers for initlab scripts. No jq dependency.

# Resolve the workbench config dir for a project root: prefer .workbench/,
# fall back to a legacy .initlab/ so adopted projects keep working pre-migration.
il_cfg_dir() { # <project_root>
  if [ -d "$1/.workbench" ]; then printf '%s\n' "$1/.workbench"
  elif [ -d "$1/.initlab" ]; then printf '%s\n' "$1/.initlab"
  else printf '%s\n' "$1/.workbench"; fi
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

# Render a .tmpl file by substituting {{KEY}} tokens. Args: <tmpl> <out> then KEY=VALUE pairs.
# Two-phase (template tokens -> sentinels -> values) so a value that itself contains a
# {{KEY}} substring is never re-scanned and clobbered. Values may contain any chars (incl. &, \).
il_render() {
  local tmpl="$1" out="$2"; shift 2
  local content pair k v
  local S1=$'\x01' S2=$'\x02'
  content="$(cat "$tmpl")"
  # phase 1: replace each template {{KEY}} with a unique sentinel (no user values yet)
  for pair in "$@"; do
    k="${pair%%=*}"
    content="${content//\{\{$k\}\}/$S1$k$S2}"
  done
  # phase 2: replace sentinels with escaped values (values are not re-scanned for tokens)
  for pair in "$@"; do
    k="${pair%%=*}"; v="${pair#*=}"
    v="${v//\\/\\\\}"   # escape backslash first
    v="${v//&/\\&}"     # then & — bash treats & in ${//} replacement as the matched text
    content="${content//$S1$k$S2/$v}"
  done
  printf '%s\n' "$content" > "$out"
}
