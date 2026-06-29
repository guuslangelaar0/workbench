#!/usr/bin/env bash
set -u; [ -f src/0001.sh ] || exit 1; source ./src/0001.sh 2>/dev/null || exit 1
chk(){ [ "$(slugify "$1" 2>/dev/null)" = "$2" ]; }
chk "Hello, World!" "hello-world" && chk "  A_B  C " "a-b-c" && chk "---x---" "x" && chk "AB12cd" "ab12cd"
