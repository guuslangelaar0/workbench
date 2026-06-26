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
