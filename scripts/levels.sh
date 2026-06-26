#!/usr/bin/env bash
# Workbench maturity-ladder preset table. The single source of truth for what
# each level (solo|pair|crew|fleet) presets across the dials. Pure bash, no deps.

wb_levels() { printf 'solo pair crew fleet\n'; }

wb_level_index() { # <level> -> 0..3 ; return 1 if unknown
  case "${1:-}" in
    solo) echo 0 ;; pair) echo 1 ;; crew) echo 2 ;; fleet) echo 3 ;;
    *) return 1 ;;
  esac
}

wb_level_lifecycle() { # <level> -> space-separated stage dirs
  case "${1:-}" in
    solo)  echo "backlog in-development verified decisions" ;;
    pair)  echo "backlog in-development in-review verified decisions" ;;
    crew)  echo "backlog in-development in-review verified staged shipped decisions" ;;
    fleet) echo "backlog in-development in-review verified staged release-candidate shipped decisions" ;;
    *) return 1 ;;
  esac
}

wb_level_dials() { # <level> -> key=value lines
  local L="${1:-}"; wb_level_index "$L" >/dev/null || return 1
  local team release decomp arch surfaces graphify loop
  case "$L" in
    solo)  team=solo;  release=push-to-main;     decomp=tasks;            arch=none;        surfaces=one;     graphify=off;       loop=auto-continue ;;
    pair)  team=pair;  release=feature-branch;   decomp=light-epics;      arch=context;     surfaces=two;     graphify=per-repo;  loop=auto-continue ;;
    crew)  team=crew;  release=tagged-releases;  decomp=epics;            arch=containers;  surfaces=several; graphify=workspace; loop=suggest-wait ;;
    fleet) team=fleet; release=release-trains;   decomp=themes-epics;     arch=components;  surfaces=many;    graphify=federated; loop=suggest-review ;;
  esac
  printf 'team=%s\nrelease=%s\ndecomposition=%s\narchitecture=%s\nsurfaces=%s\ngraphify=%s\nloop_autonomy=%s\n' \
    "$team" "$release" "$decomp" "$arch" "$surfaces" "$graphify" "$loop"
}

wb_dial() { # <project_root> <dial_name> -> resolved value (dial_overrides.<dial> if set, else level preset)
  local p="$1" d="$2"
  local cfg lvl preset override
  # lib.sh must be sourced by the caller, or we source it here if il_cfg_dir is not available
  if ! command -v il_cfg_dir >/dev/null 2>&1; then
    local _self_dir; _self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    # shellcheck source=lib.sh
    . "$_self_dir/lib.sh"
  fi
  cfg="$(il_cfg_dir "$p")/config.json"
  lvl="$(sed -n 's/.*"level"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$cfg" 2>/dev/null | head -1)"
  # Resolve dial_overrides.<dial> independent of single-/multi-line formatting and
  # without gawk: dial_overrides is a FLAT object (string values only), so flatten
  # newlines to spaces, isolate the object body between its braces, then read the
  # dial key from that body. An absent override / empty object yields nothing.
  local body
  body="$(tr '\n' ' ' < "$cfg" 2>/dev/null | sed -n 's/.*"dial_overrides"[[:space:]]*:[[:space:]]*{\([^}]*\)}.*/\1/p')"
  override="$(printf '%s' "$body" | sed -n 's/.*"'"$d"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
  if [ -n "$override" ]; then
    printf '%s\n' "$override"
    return 0
  fi
  preset="$(wb_level_dials "${lvl:-solo}" 2>/dev/null | sed -n 's/^'"$d"'=//p')"
  printf '%s\n' "${preset:-}"
}
