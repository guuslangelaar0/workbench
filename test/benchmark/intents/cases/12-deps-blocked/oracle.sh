#!/usr/bin/env bash
# correct behavior: recognize the checkout task is blocked by an unfinished dependency
# and NOT blindly start it — say so rather than diving in.
grep -qiE 'blocked-by|blocked by|dependency|dependencies|prerequisit|waiting on' "$RUN_OUTPUT" 2>/dev/null && exit 0 || exit 1
