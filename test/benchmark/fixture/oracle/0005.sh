#!/usr/bin/env bash
set -u; [ -f src/0005.sh ] || exit 1; source ./src/0005.sh 2>/dev/null || exit 1
chk(){ [ "$(roman "$1" 2>/dev/null)" = "$2" ]; }
chk 1 I && chk 4 IV && chk 9 IX && chk 40 XL && chk 58 LVIII && chk 90 XC && chk 400 CD && chk 1994 MCMXCIV && chk 3999 MMMCMXCIX
