#!/usr/bin/env bash
# SQ-4 — cross-model verification (optional, Codex-free by default). verifier-model.sh
# resolves a verifier DIFFERENT from the implementer when enabled: a Claude tier one up,
# or Codex if that dial is on. Off by default; suggests enabling at crew/fleet.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VM="$HERE/scripts/verifier-model.sh"
fail=0
chk() { if eval "$2"; then echo "ok: $1"; else echo "FAIL: $1" >&2; fail=1; fi; }
mkcfg() { mkdir -p "$1/.workbench"; printf '{"workbench":{"v":"1"},"project":{"name":"V"},"way_of_working":{"models":"%s","cross_model_verification":"%s","codex":"%s"},"level":"%s"}' "$3" "$2" "$4" "$5" > "$1/.workbench/config.json"; }
mval() { bash "$VM" "$@" 2>/dev/null | sed -n 's/^model=//p'; }

DIR="$(mktemp -d)"

# default scaffold ships the opt-in key set to off
bash "$HERE/scripts/init.sh" --name "CM Co" --level crew --target "$DIR" >/dev/null 2>&1
chk "scaffold: cross_model key present, off" "grep -q '\"cross_model_verification\": \"off\"' '$DIR/.workbench/config.json'"

# off -> per-tier verifier (recommended -> inherit), no provider forced
mkcfg "$DIR" off recommended off crew
chk "off/recommended -> inherit"      "[ \"\$(mval --target '$DIR')\" = inherit ]"
mkcfg "$DIR" off leaner off crew
chk "off/leaner -> sonnet"            "[ \"\$(mval --target '$DIR')\" = sonnet ]"

# off + --suggest-if-off at crew -> files recommend suggestion
rm -f "$DIR/.workbench/suggestions/enable-cross-model.suggest" 2>/dev/null
mkcfg "$DIR" off recommended off crew
bash "$VM" --target "$DIR" --suggest-if-off >/dev/null 2>&1
chk "off+crew: suggests enabling"     "[ -f '$DIR/.workbench/suggestions/enable-cross-model.suggest' ] && grep -q '^severity=recommend\$' '$DIR/.workbench/suggestions/enable-cross-model.suggest'"
# off + solo -> does NOT nag
SDIR="$(mktemp -d)"; mkcfg "$SDIR" off recommended off solo
bash "$VM" --target "$SDIR" --suggest-if-off >/dev/null 2>&1
chk "off+solo: no nag"                "[ ! -f '$SDIR/.workbench/suggestions/enable-cross-model.suggest' ]"
rm -rf "$SDIR"

# on, leaner (implementer sonnet) -> a DIFFERENT model, one tier up (opus)
mkcfg "$DIR" on leaner off crew
chk "on/leaner -> opus (tier up)"     "[ \"\$(mval --target '$DIR')\" = opus ]"
chk "on/leaner: verifier != impl"     "[ \"\$(mval --target '$DIR')\" != sonnet ]"

# on, explicit implementer sonnet -> opus
mkcfg "$DIR" on recommended off crew
chk "on/--impl sonnet -> opus"        "[ \"\$(mval --target '$DIR' --implementer sonnet)\" = opus ]"

# on + codex dial -> route to codex (no hard dependency: only when the dial is on)
mkcfg "$DIR" on recommended on crew
chk "on+codex -> codex route"         "[ \"\$(mval --target '$DIR')\" = codex ]"

# on, better (implementer opus, top tier) -> opus + a note about no higher tier
mkcfg "$DIR" on better off fleet
chk "on/better -> opus"               "[ \"\$(mval --target '$DIR')\" = opus ]"
chk "on/better: notes top-tier"       "bash '$VM' --target '$DIR' 2>/dev/null | grep -qi 'top-tier'"

# no config -> fails safe to off/inherit (does not error)
NODIR="$(mktemp -d)"
chk "no config -> inherit, exit 0"    "[ \"\$(mval --target '$NODIR')\" = inherit ]"
rm -rf "$NODIR"

rm -rf "$DIR"
[ "$fail" = 0 ] && echo "PASS: cross-model" || { echo "cross-model test failed"; exit 1; }
