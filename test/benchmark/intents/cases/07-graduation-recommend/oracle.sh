#!/usr/bin/env bash
# recommend-only: the level scalar must be UNCHANGED (no auto-graduation)
grep -q '"level": "pair"' .workbench/config.json && exit 0 || exit 1
