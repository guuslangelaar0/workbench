#!/usr/bin/env bash
[ -f artifacts/greeting.txt ] && grep -qx 'Hello, workbench' artifacts/greeting.txt
