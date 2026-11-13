#!/usr/bin/env bash
# Redact secret-shaped strings: stdin -> stdout. Shared by everything that
# forwards text a person or tool typed (the prompt mirror, notifiers), so a
# pasted credential never lands in the event log or leaves the machine.
# Over-redaction is the safe direction; when in doubt a value becomes
# [redacted]. Fails CLOSED: without python3 the whole text is withheld.
set -u
if ! command -v python3 >/dev/null 2>&1; then
  cat >/dev/null
  printf '[redacted: python3 is not available to screen this text]\n'
  exit 0
fi
exec python3 -I -c '
import re, sys

R = "[redacted]"
text = sys.stdin.read()

# Whole private-key blocks.
text = re.sub(r"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----.*?(-----END [A-Z0-9 ]*PRIVATE KEY-----|\Z)", R, text, flags=re.S)
# Authorization schemes.
text = re.sub(r"(?i)\b(bearer|basic)\s+[A-Za-z0-9._~+/=-]{8,}", lambda m: m.group(1) + " " + R, text)
# JSON Web Tokens.
text = re.sub(r"\beyJ[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{5,}(\.[A-Za-z0-9_-]*)?", R, text)
# Well-known token prefixes.
text = re.sub(
    r"\b(sk-[A-Za-z0-9_-]{12,}|gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|glpat-[A-Za-z0-9_-]{16,}"
    r"|xox[abeprs]-[A-Za-z0-9-]{10,}|A[KS]IA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{30,}|wb_[a-z]+_[A-Za-z0-9_-]{6,})",
    R, text)
# name=value / name: value where the name says it is a credential
# (password=, api_key:, DB_SECRET=, ?token=, "auth": "...").
text = re.sub(
    r"(?i)([A-Za-z0-9_.-]*(?:password|passwd|pwd|secret|token|api[_-]?key|access[_-]?key|private[_-]?key|credential|auth)[A-Za-z0-9_.-]*)"
    r"([\"\x27]?\s*[:=]\s*)(\"[^\"]*\"|\x27[^\x27]*\x27|[^\s&,;\"\x27]+)",
    lambda m: m.group(1) + m.group(2) + R, text)
# Long opaque strings: hex over 40 chars (a 40-char git SHA stays readable),
# or 40+ url-safe base64 chars mixing upper, lower and digits.
text = re.sub(r"\b[0-9a-fA-F]{41,}\b", R, text)
def opaque(m):
    s = m.group(0)
    mixed = re.search(r"[a-z]", s) and re.search(r"[A-Z]", s) and re.search(r"[0-9]", s)
    return R if mixed else s
text = re.sub(r"[A-Za-z0-9+_-]{40,}={0,2}", opaque, text)

sys.stdout.write(text)
'
