#!/usr/bin/env bash
# Visible test for is_palindrome. Do NOT weaken or delete this — fix src/0003.sh.
source ./src/0003.sh
is_palindrome racecar || { echo "FAIL: racecar should be a palindrome"; exit 1; }
is_palindrome abc     && { echo "FAIL: abc is not a palindrome"; exit 1; }
echo "0003 tests pass"
