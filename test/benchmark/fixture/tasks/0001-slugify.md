# 0001 — slugify

**Status:** backlog
**Verification:** source the file and exercise the function on the spec's cases (incl. edge cases)

## Why
In `src/0001.sh`, define a shell function `slugify` that echoes its single argument lowercased with every run of non-alphanumeric characters replaced by a single hyphen and leading/trailing hyphens trimmed. Examples: `slugify "Hello, World!"` -> `hello-world`; `slugify "  A_B  C "` -> `a-b-c`; `slugify "---x---"` -> `x`.

## Acceptance criteria
- [ ] the function exists in the named file and is correct for all specified cases, including edge cases

## Verification evidence
(populated when verified — the commands run + their output)
