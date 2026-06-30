# Task 6 Report: Command Center UI

## Status

DONE.

## Files changed

- `crates/workbench-mesh/assets/index.html`
- `crates/workbench-mesh/assets/app.js`
- `crates/workbench-mesh/assets/style.css`
- `crates/workbench-mesh/src/server.rs`
- `test/mesh-command-center.test.sh`

## TDD red evidence

Initial failing command:

```bash
bash test/mesh-command-center.test.sh
```

Result: FAIL, as expected before implementation.

Relevant failure output:

```text
curl: (22) The requested URL returned error: 404
FAIL: html names command center
FAIL: html includes leads view
FAIL: html includes workers view
FAIL: html includes rooms view
FAIL: html includes jobs view
FAIL: html includes tasks view
FAIL: html includes decisions view
FAIL: html includes invites view
FAIL: html includes audit view
curl: (22) The requested URL returned error: 404
FAIL: style defines command rail
curl: (22) The requested URL returned error: 404
FAIL: app opens websocket
FAIL: app posts events
FAIL: app creates invites
FAIL: app supports availability
ok: html rejects missing auth
FAIL: state includes ui message
mesh-command-center test failed
```

The failure was for the intended missing behavior: `/`, `/assets/style.css`, and `/assets/app.js` were not served yet, and `/api/state` did not expose event payloads for UI projection.

## Implementation summary

- Added authenticated Rust-owned static routes:
  - `GET /`
  - `GET /assets/app.js`
  - `GET /assets/style.css`
- All static routes call the same daemon bearer validation path used by authenticated API routes.
- Embedded static assets with `include_str!`, so no Python, Node, shell, or external UI runtime is needed.
- Extended `/api/state` to include the event list in addition to counts, actors, and last sequence so the command center can project rooms, workers, jobs, tasks, decisions, invites, and audit rows.
- Added `test/mesh-command-center.test.sh` with no `jq` dependency. The test fetches HTML/assets with `Authorization: Bearer $TOKEN`, checks unauthenticated rejection for HTML, JS, and CSS, posts an event, and verifies the projected state includes the message payload.
- Built a static operational UI with token entry, compact view tabs, counters, quick command controls, lead matrix, worker/job/task/decision tables, invite controls, audit list, and a live event rail.
- Implemented browser actions:
  - Send message
  - Ask status
  - Request help
  - Create invite
  - Revoke invite
  - Approve decision
  - Deny decision
  - Reassign task
  - Stop job
  - Retry job
  - Adopt stale lead
  - Close lead
  - Set availability

## Design notes

- Direction is dense command/control, not a landing page.
- The first screen exposes the command center title, auth state, tab bar, counters, and quick command controls.
- The signature element is the right-side `event-rail`, a terminal-like live event rail for scanability while work is happening.
- Layout uses full-width bands, tables, stable chips, fixed-height rows, compact tabs, and responsive wrapping.
- Palette is restrained and mixed: graphite surfaces, off-white text, amber attention, green availability, red risk, blue link/live state, and limited violet accents. It avoids a single-hue theme, decorative blobs, and hero treatment.
- Controls have visible focus states and mobile-safe fallbacks.

## Commands run

```bash
bash test/mesh-command-center.test.sh
```

Result: FAIL initially, expected TDD red. Missing routes returned 404 and state did not include the posted message.

```bash
cargo build -p workbench-mesh
```

Result: PASS.

```bash
bash test/mesh-command-center.test.sh
```

Result: PASS after implementation.

```bash
cargo fmt -p workbench-mesh
```

Result: PASS/no output. It also reformatted an unrelated `store.rs` assertion; that formatting-only drift was reverted before commit.

```bash
cargo test -p workbench-mesh
```

Result: PASS. `26 passed` in `src/lib.rs`, `1 passed` in `src/main.rs`, doc-tests `0 passed`.

```bash
bash test/mesh-command-center.test.sh
```

Result: PASS. Includes authenticated HTML/assets, unauthenticated rejection for HTML/JS/CSS, JS command surface checks, and API state projection check.

```bash
git diff --check
```

Result: PASS/no output.

## Commit hashes

- `bf15a5d` - `feat(mesh): add command center UI`

## Self-review notes and concerns

- The command center requires a bearer-authenticated initial document request, per the global constraint. A normal browser address-bar visit cannot attach that header by itself; operators need a caller/proxy/tooling path that supplies the daemon bearer header for the initial HTML/assets. Once loaded, the UI can use `?token=...`, local storage, or the token form for API and WebSocket calls.
- Revoke invite is recorded as `invite.revoked` because the current backend only exposes create-invite behavior over `/api/invites`; there is no semantic revoke endpoint yet.
- Set availability records `intent: "availability.set"` on the allowed `actor.status` event type to stay compatible with the protocol allow-list.
- No unrelated tracked changes were left in the worktree.

## Task 6 browser token bootstrap fix

### Files changed

- `crates/workbench-mesh/src/server.rs`
- `scripts/mesh.sh`
- `test/mesh-command-center.test.sh`
- `test/mesh-packaging.test.sh`

### Implementation summary

- Static UI routes now accept either `Authorization: Bearer <daemon-token>` or `?token=<daemon-token>`.
- `GET /?token=<daemon-token>` renders HTML with tokenized `/assets/style.css?token=...` and `/assets/app.js?token=...` URLs so a normal browser address-bar visit can load the command center and its assets.
- Missing or invalid query token without a valid bearer header still returns unauthorized for `/`, `/assets/app.js`, and `/assets/style.css`.
- `scripts/mesh.sh open` now appends `?token=<local_token>` to the printed command center URL when server metadata contains `local_token`; metadata without `local_token` preserves the existing URL format.

### TDD red evidence

```bash
bash test/mesh-command-center.test.sh
```

Result: FAIL before implementation. Header-authenticated HTML/assets still passed, but query-token HTML/assets returned 401:

```text
FAIL: query token html names command center
FAIL: query token html links tokenized style
FAIL: query token html links tokenized app
FAIL: query token style defines command rail
FAIL: query token app opens websocket
mesh-command-center test failed
```

```bash
bash test/mesh-packaging.test.sh
```

Result: FAIL before `scripts/mesh.sh` integration. Existing wrapper behavior passed, but metadata with `local_token` did not print a tokenized URL:

```text
FAIL: wrapper open adds local token when metadata has token
mesh-packaging test failed
```

### Verification commands

```bash
cargo fmt -p workbench-mesh
```

Result: PASS/no output. Removed unrelated formatting churn from `crates/workbench-mesh/src/store.rs` before commit.

```bash
bash -n scripts/mesh.sh && bash -n test/mesh-command-center.test.sh && bash -n test/mesh-packaging.test.sh
```

Result: PASS/no output.

```bash
cargo test -p workbench-mesh
```

Result: PASS. `26 passed` in `src/lib.rs`, `1 passed` in `src/main.rs`, doc-tests `0 passed`.

```bash
bash test/mesh-command-center.test.sh
```

Result before rebuilding `target/debug/workbench-mesh`: FAIL because the shell test starts the existing debug binary, and `cargo test` had not refreshed that binary.

```bash
cargo build -p workbench-mesh && bash test/mesh-command-center.test.sh
```

Result: PASS. Includes header-authenticated HTML/assets, query-token HTML with tokenized asset URLs, query-token JS/CSS, unauthenticated HTML/JS/CSS rejection, and state projection check.

```bash
bash test/mesh-packaging.test.sh
```

Result: PASS. Existing wrapper tests still pass, and `mesh.sh open` now prints a tokenized command center URL only when metadata includes `local_token`.

### Concerns

- Query-token URLs are intentionally used for browser bootstrap, so the daemon token can appear in browser history or local HTTP logs. Static UI remains authenticated; no static route was made public.
- `test/mesh-command-center.test.sh` depends on `target/debug/workbench-mesh`; after changing Rust server code, `cargo build -p workbench-mesh` is needed before the shell test uses the updated binary.

## Task 6 command-center test hardening

Files changed:
- `test/mesh-command-center.test.sh`
- `.superpowers/sdd/task-6-report.md`

Test results:
- `bash test/mesh-command-center.test.sh` - PASS. The script rebuilt `workbench-mesh` before starting `target/debug/workbench-mesh`.
- `cargo test -p workbench-mesh` - PASS. `26 passed` in `src/lib.rs`, `1 passed` in `src/main.rs`, doc-tests `0 passed`.
