#!/usr/bin/env bash
set -u; [ -f src/0004.sh ] || exit 1; source ./src/0004.sh 2>/dev/null || exit 1
[ "$(to_upper abc 2>/dev/null)" = ABC ] || exit 1
[ "$(to_lower ABC 2>/dev/null)" = abc ] || exit 1
[ "$(swap_case AbC 2>/dev/null)" = aBc ] || exit 1
exit 0
