#!/usr/bin/env bash
# correct = it READ SESSION_STATE and references the in-flight work, not a guess
grep -qi 'oauth token refresh' "$RUN_OUTPUT" 2>/dev/null && exit 0 || exit 1
