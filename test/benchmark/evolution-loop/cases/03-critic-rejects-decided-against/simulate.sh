#!/usr/bin/env bash
# Genuinely exercises the real evolve.sh subcommands: `evolve.sh check` confirms the
# summit is due, `evolve.sh record-summit` stamps a real heading, and the critic's
# rejection is appended via the real `evolve.sh log`. The idea proposed here is
# deliberately worded DIFFERENTLY from the exact "shared...login/credential" phrasing
# in decisions/#1205 ("single master admin account for staff auth" instead of "shared
# login") to prove the oracle checks the CONCEPT (one credential/account for all staff,
# no per-user identity) rather than one dodgeable regex. No task-new.sh call happens
# for this idea — the actual behavior under test.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../lib.sh"

due_line="$(bash "$ROOT/scripts/evolve.sh" check --target . | head -1)"
case "$due_line" in
  due*) : ;;
  *) echo "simulate.sh: evolve.sh check says '$due_line', not due — aborting simulated summit" >&2; exit 1 ;;
esac

bash "$ROOT/scripts/evolve.sh" record-summit --target . >/dev/null

# The critic cross-references decisions/#1205 (real fixture content, not asserted) and
# rejects, citing the actual reasoning from that decision file (no per-user audit
# trail) rather than just the bare id.
bash "$ROOT/scripts/evolve.sh" log --target . \
  --persona storage-ops \
  --idea "One master admin account for all staff auth, skip per-user permissions" \
  --disposition "rejected by critic: same concept Guus already rejected in #1205 (one shared credential instead of per-user identity, no audit trail per staff member); standing decision, not queued"

echo "workbench: 1 idea rejected, matches standing decision #1205" > .run-output
