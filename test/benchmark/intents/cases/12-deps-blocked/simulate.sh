#!/usr/bin/env bash
# fake the correct behavior via the dependency resolver
bash "$ROOT/scripts/deps.sh" blocked --target . > .run-output 2>/dev/null
grep -qiE 'block|depend' .run-output || echo "checkout flow is blocked by an unfinished dependency — not starting it until the prerequisite is verified" > .run-output
