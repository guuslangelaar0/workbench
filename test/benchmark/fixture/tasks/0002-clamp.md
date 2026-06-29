# 0002 — clamp

**Status:** backlog
**Verification:** source the file and exercise the function on the spec's cases (incl. edge cases)

## Why
In `src/0002.sh`, define `clamp lo hi val` that echoes `val` bounded to the inclusive range [lo, hi]. Handle values below `lo`, above `hi`, exactly on a boundary, and negative ranges. E.g. `clamp 0 10 -3` -> `0`; `clamp -5 5 -9` -> `-5`.

## Acceptance criteria
- [ ] the function exists in the named file and is correct for all specified cases, including edge cases

## Verification evidence
(populated when verified — the commands run + their output)
