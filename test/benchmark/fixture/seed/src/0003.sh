is_palindrome() {
  # BUG: this always reports "palindrome" — fix it so the test suite passes.
  local s="$1"
  [ -n "$s" ] || return 0
  return 0
}
