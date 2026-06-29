#!/usr/bin/env bash
[ -f artifacts/sum.txt ] && [ "$(tr -d ' \n' < artifacts/sum.txt)" = 9 ]
