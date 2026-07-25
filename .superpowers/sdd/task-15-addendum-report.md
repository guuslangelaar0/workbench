# Task 15 addendum — dashboard copy fix (lan mode TLS mischaracterization)

Small follow-up requested after a task reviewer manually browsed the command-center
dashboard and found stale "lan mode is unencrypted" copy left over from before this
branch added self-signed-cert TLS + fingerprint pinning to `--lan` mode.

## Scope check

Grepped the whole repo for `no TLS|plaintext HTTP|unencrypted` across `*.js`, `*.md`,
`*.html`. Found 4 live occurrences (not the 3 the reviewer named — `data.js` had two),
all in `crates/workbench-mesh/assets/command-center/`. No README, slash-command doc,
or skill doc made the same claim. The only other repo hits were historical/inert:
- `docs/superpowers/plans/2026-07-03-mesh-realtime-protocol.md:2564` — a dated plan
  snapshot from *before* this branch existed; accurate description of the code at the
  time it was written. Left untouched (not live docs).
- `docs/superpowers/specs/2026-07-05-mesh-lan-tls-pinning-design.md` — this branch's
  own design doc, describing the *problem being fixed*, not current behavior. Left
  untouched.
- `skills/task-lifecycle/SKILL.md:22` and the intents-benchmark `13-security-bug`
  fixture — an unrelated "plaintext-password leak" example, not about lan mode TLS.
  Left untouched.

## Files changed

### `crates/workbench-mesh/assets/command-center/data.js:108` (WB.WHAT_IS_NOT)
- Old: `'Not a hosted, multi-tenant product — no public internet exposure, no TLS by design.'`
- New: `'Not a hosted, multi-tenant product — no public internet exposure, no CA-trusted TLS, by design.'`

### `crates/workbench-mesh/assets/command-center/data.js:229` (WB.FAQ)
- Old: `{ q: 'Is this safe to run outside my LAN?', a: 'No — LAN mode is plaintext HTTP with bearer-token auth, trusted-LAN only, by design. There’s no TLS and no public exposure.' }`
- New: `{ q: 'Is this safe to run outside my LAN?', a: 'No — LAN mode is TLS-encrypted with a self-signed cert pinned by fingerprint, bearer-token auth, trusted-LAN only, by design. There’s no CA-trusted cert and no public exposure.' }`

### `crates/workbench-mesh/assets/command-center/app.js:131` (statusline chip)
- Old: `el('span', { class: 'sl-item sl-dim', text: 'trusted LAN · plaintext HTTP' }),`
- New: `el('span', { class: 'sl-item sl-dim', text: 'trusted LAN · TLS pinned' }),`

### `crates/workbench-mesh/assets/command-center/host.js:318` (Host screen lan-note)
- Old: `el('div', { class: 'lan-note', html: svgIcon('shield', 11) + ' local + trusted-LAN surface · plaintext HTTP with bearer tokens · no public exposure, no TLS — by design' }),`
- New: `el('div', { class: 'lan-note', html: svgIcon('shield', 11) + ' local + trusted-LAN surface · bearer tokens · LAN is TLS-pinned (self-signed), local is plain HTTP · no public exposure — by design' }),`

This last one previously described `local` and `lan` mode with one combined claim
("plaintext HTTP ... no TLS") that was true for both before this branch. Since the
two modes now differ, the note explicitly separates them: `local is plain HTTP`
(true, unchanged, byte-for-byte preserved as a factual claim) vs `LAN is TLS-pinned
(self-signed)` (the corrected claim).

No wording invents cipher suites, TLS versions, or other implementation detail not
already present in the surrounding copy — only the true/false characterization of
whether lan mode has TLS, and the necessary caveat that the cert is self-signed /
not CA-trusted (matching `PinnedCertVerifier` in `crates/workbench-mesh/src/tls.rs`
and the mode split in `crates/workbench-mesh/src/server.rs::serve()`, confirmed by
reading both before writing new copy).

## Verification

- `bash test/all.sh` — full suite, exit 0, `ALL TESTS PASS`.
- `bash test/mesh-command-center.test.sh` run standalone for extra confidence on the
  touched surface — all cases green, including the Task 13 TLS/fingerprint lan
  enrollment cases.
- Confirmed no test in the repo asserted the old stale copy verbatim (grepped test/
  for the exact old strings and for `WHAT_IS_NOT`/`sl-dim`/`lan-note` — no hits tied
  to this text), so no test needed correcting alongside the copy.
- Post-fix repo grep: `grep -rn "no TLS\|plaintext" --include="*.js" .` → no hits.
  Equivalent doc grep → only the historical/inert hits listed above under "Scope
  check", none of which describe current live behavior.

## Commit

`fix(mesh): dashboard copy reflects lan mode's TLS pinning, not plaintext HTTP`

Staged only the 3 changed frontend files (`app.js`, `data.js`, `host.js`) plus this
report. The pre-existing unrelated modification to `.superpowers/sdd/task-7-report.md`
and the untracked `.playwright-mcp/` and `.workbench/` dirs were left alone, per
instructions.
