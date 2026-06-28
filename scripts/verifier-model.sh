#!/usr/bin/env bash
# workbench: resolve which model should VERIFY a task. A same-model verifier shares the
# implementer's blind spots and rubber-stamps (LLM-as-judge self-enhancement bias).
# Cross-model verification breaks "the judge is the player" — and the key point: it needs
# NO second tool. A different Claude TIER (a stronger skeptic, one tier up) already gives
# most of the benefit. Codex / another provider is just one option among others, never required.
#
# Reads way_of_working.cross_model_verification (off|on, default off) + .models tier + .codex.
# OFF  -> the normal per-tier verifier (orchestration's default); optionally suggests enabling.
# ON   -> a model DIFFERENT from the implementer: codex (if the codex dial is on) else a
#         Claude tier one step up (sonnet->opus, haiku->sonnet, opus->opus+note).
#
# Usage: verifier-model.sh [--implementer MODEL] [--target DIR] [--suggest-if-off]
# Output (stdout): two lines — `model=<resolved>` and `note=<rationale>`.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SELF_DIR/lib.sh"

IMPL="" TARGET="$PWD" SUGGEST=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --implementer)   IMPL="$2"; shift 2 ;;
    --target)        TARGET="$2"; shift 2 ;;
    --suggest-if-off) SUGGEST=1; shift ;;
    -*) echo "verifier-model.sh: unknown flag '$1'" >&2; exit 64 ;;
    *)  echo "verifier-model.sh: unexpected arg '$1'" >&2; exit 64 ;;
  esac
done
TARGET="${TARGET%/}"; [ -n "$TARGET" ] || TARGET="/"
CFG="$(il_cfg_dir "$TARGET")/config.json"
cfg() { sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$CFG" 2>/dev/null | head -1; }

cross="off" tier="recommended" codex="off" level=""
if [ -f "$CFG" ]; then
  c="$(cfg cross_model_verification)"; [ -n "$c" ] && cross="$c"
  t="$(cfg models)"; [ -n "$t" ] && tier="$t"
  x="$(cfg codex)"; [ -n "$x" ] && codex="$x"
  level="$(cfg level)"
fi

# per-tier default implementer/verifier model (mirrors the `models` skill table)
tier_model() { case "$1" in leaner) echo sonnet ;; better) echo opus ;; *) echo inherit ;; esac; }
# one tier up from a concrete model (a stronger skeptic)
one_up() { case "$1" in haiku) echo sonnet ;; sonnet) echo opus ;; opus) echo opus ;; *) echo opus ;; esac; }

emit() { printf 'model=%s\nnote=%s\n' "$1" "$2"; }

if [ "$cross" != "on" ]; then
  vm="$(tier_model "$tier")"
  # producer: at crew/fleet, recommend enabling cross-model hardening (recommend-only)
  if [ "$SUGGEST" = 1 ] && [ -x "$SELF_DIR/suggest.sh" ]; then
    case "$level" in
      crew|fleet) bash "$SELF_DIR/suggest.sh" add --key enable-cross-model --severity recommend \
          --title "Enable cross-model verification (a stronger skeptic, no extra tool)" \
          --why "the verifier currently shares the implementer's model and blind spots; a different Claude tier breaks rubber-stamping with zero extra setup" \
          --how "set way_of_working.cross_model_verification = \"on\" in .workbench/config.json (Codex optional, not required)" \
          --source verification --target "$TARGET" >/dev/null 2>&1 || true ;;
    esac
  fi
  emit "$vm" "cross-model off — per-tier verifier ('$tier'); enable cross_model_verification for an independent skeptic"
  exit 0
fi

# cross-model ON
impl="$IMPL"; [ -n "$impl" ] || impl="$(tier_model "$tier")"
if [ "$codex" = "on" ]; then
  emit "codex" "cross-model on + codex dial on — route the verifier to Codex (independent provider) for true cross-model review"
  exit 0
fi
# resolve a concrete implementer for the tier-up step ('inherit' -> assume opus session, the common case)
impl_concrete="$impl"; [ "$impl_concrete" = inherit ] && impl_concrete=opus
vm="$(one_up "$impl_concrete")"
if [ "$vm" = "$impl_concrete" ]; then
  emit "$vm" "cross-model on — implementer is already top-tier ($impl_concrete); no higher Claude tier. Use a fresh adversarial verifier context, or turn on the codex dial for a different provider."
else
  emit "$vm" "cross-model on — verifier '$vm' is one tier above the implementer '$impl_concrete' (a stronger, independent skeptic). No second tool needed; Codex optional."
fi
exit 0
