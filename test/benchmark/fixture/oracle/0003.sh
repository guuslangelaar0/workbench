#!/usr/bin/env bash
[ -f artifacts/rev.txt ] && [ "$(tr -d ' \n' < artifacts/rev.txt)" = cba ]
