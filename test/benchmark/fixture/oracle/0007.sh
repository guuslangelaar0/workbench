#!/usr/bin/env bash
set -u; [ -f src/0007.sh ] || exit 1; source ./src/0007.sh 2>/dev/null || exit 1
chk(){ [ "$(roman_to_int "$1" 2>/dev/null)" = "$2" ]; }
chk I 1 && chk IV 4 && chk IX 9 && chk LVIII 58 && chk XC 90 && chk CD 400 && chk MCMXCIV 1994 && chk MMMCMXCIX 3999
