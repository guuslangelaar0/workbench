# 0006 — balanced

**Status:** backlog
**Verification:** source the file and exercise the function on the spec's cases (incl. edge cases)

## Why
In `src/0006.sh`, define `balanced s` that returns success (exit 0) iff the brackets in `s` — `()`, `[]`, `{}` — are balanced and correctly nested, ignoring every other character. Return failure (exit 1) otherwise. E.g. `"([{}])"` and `"a(b)c"` are balanced; `"(]"`, `"(()"`, `"]"`, and `"{[}]"` are not. The empty string is balanced.

## Acceptance criteria
- [ ] the function exists in the named file and is correct for all specified cases, including mismatched-type, wrong-nesting, and unclosed/unopened edge cases

## Verification evidence
(populated when verified — the commands run + their output)
