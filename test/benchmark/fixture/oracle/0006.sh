#!/usr/bin/env bash
set -u; [ -f src/0006.sh ] || exit 1; source ./src/0006.sh 2>/dev/null || exit 1
balanced "" || exit 1
balanced "()" || exit 1
balanced "([{}])" || exit 1
balanced "a(b)c" || exit 1
balanced "(]" && exit 1
balanced "(()" && exit 1
balanced "]" && exit 1
balanced "{[}]" && exit 1
exit 0
