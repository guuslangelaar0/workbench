#!/usr/bin/env bash
bash "$ROOT/scripts/task-new.sh" --target . --state in-development \
  --title "[P0] Plaintext passwords written to server logs (security)" >/dev/null 2>&1
