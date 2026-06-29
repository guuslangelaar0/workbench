#!/usr/bin/env bash
set -u; [ -f src/0003.sh ] || exit 1; source ./src/0003.sh 2>/dev/null || exit 1
is_palindrome racecar || exit 1
is_palindrome abc && exit 1
is_palindrome "" || exit 1
is_palindrome a || exit 1
is_palindrome ab && exit 1
is_palindrome level || exit 1
exit 0
