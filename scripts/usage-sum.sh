#!/usr/bin/env bash
# workbench: sum exact token usage from a Claude Code session transcript JSONL.
# Each `assistant` record carries message.usage.{input_tokens, output_tokens,
# cache_read_input_tokens, cache_creation_input_tokens} — the real API response,
# the ground truth for spend. Prints ONE TAB-separated line:
#     input<TAB>output<TAB>cache_read<TAB>cache_write<TAB>turns<TAB>source
# `source` is exact (python3/jq parse) or estimate (awk fallback; may overcount
# nested per-iteration usage). FAILS OPEN: prints zeros + source=none on any error.
#
# Usage: usage-sum.sh <transcript.jsonl>
set -uo pipefail
F="${1:-}"
emit() { printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" "$6"; }
[ -n "$F" ] && [ -f "$F" ] || { emit 0 0 0 0 0 none; exit 0; }

# --- exact: python3 (parses message.usage only; ignores nested iterations) ---
if command -v python3 >/dev/null 2>&1; then
  out="$(python3 - "$F" <<'PY' 2>/dev/null
import json, sys
i=o=cr=cw=t=0
for line in open(sys.argv[1], encoding="utf-8", errors="replace"):
    line=line.strip()
    if not line: continue
    try: r=json.loads(line)
    except Exception: continue
    if r.get("type")!="assistant": continue
    u=(r.get("message") or {}).get("usage") or {}
    if not isinstance(u,dict): continue
    i  += int(u.get("input_tokens",0) or 0)
    o  += int(u.get("output_tokens",0) or 0)
    cr += int(u.get("cache_read_input_tokens",0) or 0)
    cw += int(u.get("cache_creation_input_tokens",0) or 0)
    t  += 1
print("%d\t%d\t%d\t%d\t%d\texact" % (i,o,cr,cw,t))
PY
)"
  [ -n "$out" ] && { printf '%s\n' "$out"; exit 0; }
fi

# --- exact: jq (one usage object per assistant record) ---
if command -v jq >/dev/null 2>&1; then
  out="$(jq -rs '
    [ .[] | select(.type=="assistant") | .message.usage // {} ] as $u
    | [ ($u|map(.input_tokens//0)|add), ($u|map(.output_tokens//0)|add),
        ($u|map(.cache_read_input_tokens//0)|add), ($u|map(.cache_creation_input_tokens//0)|add),
        ($u|length) ] | @tsv' "$F" 2>/dev/null)"
  [ -n "$out" ] && { printf '%s\texact\n' "$out"; exit 0; }
fi

# --- estimate: awk fallback (per-assistant-line; takes FIRST match of each key to
#     avoid summing nested iteration usage). Marked `estimate` — it is best-effort. ---
awk '
  function first(key,   s) {
    if (match($0, "\"" key "\":[ ]*[0-9]+")) { s=substr($0,RSTART,RLENGTH); gsub(/[^0-9]/,"",s); return s+0 }
    return 0
  }
  /"type"[ ]*:[ ]*"assistant"/ {
    i+=first("input_tokens"); o+=first("output_tokens");
    cr+=first("cache_read_input_tokens"); cw+=first("cache_creation_input_tokens"); t++
  }
  END { printf "%d\t%d\t%d\t%d\t%d\testimate\n", i+0, o+0, cr+0, cw+0, t+0 }
' "$F" 2>/dev/null || emit 0 0 0 0 0 none
