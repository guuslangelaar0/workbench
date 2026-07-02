#!/usr/bin/env bash
# correct = it READ SESSION_STATE and references the in-flight work, not a guess
if grep -qiE "stale|contradict|didn't hold up|nothing to continue|no actual evidence" "$RUN_OUTPUT" 2>/dev/null; then
  exit 1
fi
grep -qiE 'oauth[ -]token[ -]refresh|auth-refresh|task 0001' "$RUN_OUTPUT" 2>/dev/null && exit 0 || exit 1
