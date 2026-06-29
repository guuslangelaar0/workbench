#!/usr/bin/env bash
set -u; [ -f src/0002.sh ] || exit 1; source ./src/0002.sh 2>/dev/null || exit 1
chk(){ [ "$(clamp "$1" "$2" "$3" 2>/dev/null)" = "$4" ]; }
chk 0 10 5 5 && chk 0 10 -3 0 && chk 0 10 99 10 && chk 0 10 0 0 && chk -5 5 -9 -5 && chk -5 5 5 5
