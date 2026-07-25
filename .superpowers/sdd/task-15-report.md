# Task 15 report — End-to-end negative-path and regression test sweep

(Note: this file previously held a report for an unrelated earlier task also
numbered 15 from a different plan document — "Frontend: app-level ping/pong
RTT + presence-freshness from receipts." That work is untouched by this
task; this file is overwritten per this task's own explicit instruction to
write the Task 15 report here.)

## Model note

Per the dispatch instructions, this task was executed by Sonnet 5 directly
(not delegated to Fable 5), consistent with the plan's Task 4 precedent that
Fable 5 is reserved for narrow research/verification calls, not full
security-critical task implementation.

## What changed

- `crates/workbench-mesh/src/server.rs:2273-2322` — added
  `end_to_end_wrong_fingerprint_is_rejected_by_a_real_connect`, a new
  `#[tokio::test]` in the existing `mod tests` block, inserted immediately
  after `lan_mode_serves_https_and_local_mode_still_serves_plain_http`
  (thematically adjacent: both spin up a real `serve()` in `lan` mode and
  exercise TLS pinning end-to-end).
- No production code was changed — this task is test-only, as specified.

Diff stat: `crates/workbench-mesh/src/server.rs | 50 +++++++++++++++++++++++++++++++++++++` (50 insertions, 0 deletions).

## Signature verification against the brief (Step 0, before adding the test)

Read the current signatures before pasting the brief's test body:

- `ServeOptions { project_root, home, bind, port, pid_file, started_by }` —
  `crates/workbench-mesh/src/server.rs:98-105` — matches the brief's literal
  struct-init verbatim.
- `pub async fn serve(opts: ServeOptions) -> Result<()>` —
  `crates/workbench-mesh/src/server.rs:296` — matches.
- `pub fn read_server_metadata(project_root: &Path) -> Result<ServerMetadata>` —
  `crates/workbench-mesh/src/server.rs:470` — matches (already imported into
  the test module via the existing `use super::{read_server_metadata, serve,
  server_metadata_path, AppState, ChannelRegistry, ServeOptions};`).
- `pub fn bootstrap(project_root: &Path, home: Option<PathBuf>) -> Result<String>` —
  `crates/workbench-mesh/src/auth.rs:87` — matches the brief's
  `auth::bootstrap(host_tmp.path(), None).unwrap();` call (return type is
  `Result<String>`, not `Result<()>`, but `.unwrap()` is call-signature
  agnostic to that, so no fix needed).
- `pub fn create_invite(project_root: &Path, home: Option<PathBuf>, role: &str, ttl_seconds: u64, max_uses: u32) -> Result<Invite>` —
  `crates/workbench-mesh/src/auth.rs:115` — matches
  `auth::create_invite(host_tmp.path(), None, "worker", 3600, 1)` verbatim,
  and `Invite.token: String` (`crates/workbench-mesh/src/auth.rs:27`) matches
  `invite.token.clone()`.
- `pub fn encode_fingerprint(fp: &[u8; 16]) -> String` and
  `pub fn decode_fingerprint(s: &str) -> Result<[u8; 16]>` —
  `crates/workbench-mesh/src/tls.rs:106-118` — matches; fingerprint is a
  truncated 128-bit (16-byte) SHA-256 digest, so `wrong[0] ^= 0xFF` on the
  decoded `[u8; 16]` array is valid.
- `pub async fn accept_remote_invite(project_root: PathBuf, home: Option<PathBuf>, url: String, token: String, device: String, fingerprint: Option<String>, yes: bool) -> Result<()>` —
  `crates/workbench-mesh/src/client.rs:184-192` — matches the brief's call
  **exactly**, including the post-Task-10/11 parameter order
  (`fingerprint: Option<String>` before `yes: bool`). **No signature fix was
  needed** — the brief's call in Step 1 was already correct against current
  `main` of this branch.

## Deviation from the brief (noted, not a signature fix)

The brief's literal test body synchronizes on the server coming up with:

```rust
tokio::time::sleep(Duration::from_millis(200)).await;
let host_metadata = read_server_metadata(host_tmp.path()).unwrap();
```

Every other full-stack test in this file (23 call sites) instead uses the
existing `wait_for_metadata(project: &Path) -> ServerMetadata` helper
(`crates/workbench-mesh/src/server.rs:2968-2976`), which polls up to 50 × 20ms
= 1s for the metadata file to appear before reading it — strictly more robust
than a fixed 200ms sleep, with identical semantics on success. I substituted
`let host_metadata = wait_for_metadata(host_tmp.path()).await;` for the
brief's sleep+read pair, to match the file's established convention and
reduce flakiness risk on this specific test, which is explicitly called out
as "the single most important test in the entire 15-task plan." This is the
**only** deviation from the brief's test body; every assertion, the
byte-flip logic, the call to `accept_remote_invite`, and the trailing
comment block are verbatim from the brief. I also used `client::` (already
imported via `use crate::client;` in the test module, and the convention
used one line below by `remote_invite_accept_requires_expected_project`)
rather than the brief's fully-qualified `crate::client::` — functionally
identical, matching local file style.

The brief's trailing comment (lines 54-60 of the brief) describes a
positive-path re-connect with the correct fingerprint that is **not actually
implemented in code** — it is comment-only in the brief itself, immediately
followed by `handle.abort();`. I added it verbatim as a comment (no code was
dropped) since the brief marks the test body "complete and correct" and my
mandate was to fix only genuine signature mismatches.

## Step 2 — first run, proof this is regression-only

```
cargo test -p workbench-mesh end_to_end_wrong_fingerprint -- --nocapture
```

```
running 1 test
test server::tests::end_to_end_wrong_fingerprint_is_rejected_by_a_real_connect ... ok

test result: ok. 1 passed; 0 failed; 0 ignored; 0 measured; 152 filtered out; finished in 0.07s
```

PASSED on first run, and reconfirmed stable across 3 repeated runs (0.06s–0.13s
each, no flakes). This confirms Tasks 1-11's real `serve()` + real
`client::accept_remote_invite()` path genuinely rejects a byte-flipped
fingerprint end-to-end — **no gap found**, no weakening was needed.

## Step 3 — full crate suite

```
cargo test -p workbench-mesh
```

```
test result: ok. 153 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.78s   (lib)
test result: ok. 5 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s     (bin)
test result: ok. 0 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s     (doc-tests)
```

153 lib tests (152 pre-existing + 1 new), 5 bin tests, 0 doc tests — fully
green. Re-ran a second time after Step 5's manual work to confirm nothing in
the manual check perturbed the suite; same 153/5/0 result.

## Step 4 — full repository suite

```
bash test/all.sh
```

Final lines:
```
ok: release gate evidence is gitignored
PASS: release-gate
ALL TESTS PASS
```

1474 individual `ok:` assertions across all 68 sub-suites (skeleton, levels,
templates, ..., mesh-protocol, mesh-auth, mesh-service, mesh-ops,
mesh-packaging, mesh-command-center, mesh-channel, mesh-hooks,
mesh-plugin-outcome, ..., release-gate), zero `FAIL`/`not ok` lines, exit
code 0. Ran in 1:58 wall clock (32s user, 48s system).

Note on process: my first attempt ran `test/all.sh` via the `run_in_background`
Bash mechanism; that background job (and a second background watcher job)
were silently torn down with no completion notification ever delivered
(their output files ended up empty and the log was truncated mid-run at
"expectancy-gate" with no process left alive) after a coordinator message
interrupted the turn. This looks like an artifact of this specific
environment/session, not the test suite itself. I re-ran the full suite
synchronously in the foreground instead, which completed cleanly with a
clear PASS in under 2 minutes — no code or test changes were needed to get a
clean run.

## Step 5 — manual dashboard/browser check (real, not simulated)

### Setup and a genuine finding along the way

`scripts/mesh.sh start --lan`'s binary-resolution shim (`bin/workbench-mesh`)
prefers `target/release/workbench-mesh` over `target/debug/workbench-mesh`
when both exist. The pre-existing `target/release/workbench-mesh` in this
checkout was dated **Jul 5 03:29**, which **predates this entire branch's TLS
work** (`feat/mesh-lan-tls-pinning` started well after that). Starting `mesh
start --lan` against it produced a running server whose
`.workbench/mesh/server.json` had **no `tls_fingerprint` field and no
`.workbench/mesh/tls/` directory** — i.e., a stale binary from before Task 1
silently served plaintext-shaped metadata while the banner text (a static
shell-script string, unconditional on `--lan`) still printed `https://`
URLs, which would have been a misleading, wrong signal for this verification
step. I killed that process, ran `cargo build -p workbench-mesh --release`
to rebuild from current source (confirmed via `strings | grep
tls_fingerprint` that the old binary had none of this branch's TLS strings
and the rebuilt one does), and restarted. This is a **process/tooling gotcha
in this environment**, not a defect in Tasks 1-14's code — the actual crate
source and its 153 passing tests were never in doubt — but it's worth
flagging so future manual checks in this repo rebuild (or otherwise force) a
fresh binary rather than trusting whatever `target/release/` happens to
contain.

After rebuild, `.workbench/mesh/server.json` correctly showed:
```json
{
  "mode": "lan", "host": "10.100.0.238", "port": 47321,
  "tls_fingerprint": "I-eWh115zbYdc3ZMXq1sKw", ...
}
```
and `.workbench/mesh/tls/{cert.pem,key.pem,identity.lock}` existed.

### (a) Certificate warning appears — confirmed expected, not a regression

Navigated a real Chrome instance (chrome-devtools MCP) to
`https://127.0.0.1:47321/` and separately to
`https://10.100.0.238:47321/?token=<local_token>` (the exact URL
`scripts/mesh.sh open` prints for a real user). Both hit Chrome's real
interstitial: **"Your connection is not private" / NET::ERR_CERT_AUTHORITY_INVALID**.
This is expected — the server uses a self-signed certificate by design, and
no CA is installed for it in this browser profile. Screenshot:
`/tmp/claude-1000/-home-guus-code-workbench/db2a8692-420d-48e3-8d17-019b15fb99a0/scratchpad/mesh-manual-check/screenshots/01-cert-warning.png`.

### (b) Clicking through loads the real dashboard — confirmed

Clicked "Advanced" → "Proceed to 10.100.0.238 (unsafe)" (the tool's `click`
against the interstitial's accessibility-tree "proceed" link). The real
command-center HTML loaded: page title "Workbench Mesh — Command Center",
visible Bench/Board/Host/Ops/Docs tabs, a Team Chat panel, and a live status
bar reading `Legion:47321 · lan 10.100.0.238 · daemon up 1m · started by
unknown · seq #0 · 1ms · you: operator · token ok`. This is the genuine
command-center UI, not a stub or error page (an unauthenticated/wrong-token
request to `/` returns a bare `{"error":"unauthorized"}` JSON body, which I
also observed once by accident on a plain reload that dropped the query
token — confirming the 200-with-full-HTML response is specifically gated on
a valid token, not just any request to `/`). Screenshots:
`.../screenshots/03-dashboard-with-token.png` and
`.../screenshots/04-dashboard-full.png`.

### (c) The dashboard's `wss://` WebSocket connects without error — confirmed

`list_console_messages` showed **zero** console messages (no errors/warnings)
throughout. Two independent positive-evidence checks:

1. `window.WB.RTT` (set by the app's own 5-second ping/pong loop in
   `live.js`) read `2` (milliseconds) — i.e., a real ping was sent over the
   socket and a pong was received and timed, and it stayed at `2` across a
   6-second wait, showing an ongoing live connection, not a one-off fluke.
2. Injected an `initScript` via `navigate_page` that wraps `window.WebSocket`
   to log construction/open/error/close events, then re-navigated. Console
   output:
   ```
   [WS-PROBE] constructing wss://10.100.0.238:47321/ws?token=...&last_seq=0
   [WS-PROBE] OPEN wss://10.100.0.238:47321/ws?token=...&last_seq=0
   ```
   with **no** `[WS-PROBE] ERROR` or `[WS-PROBE] CLOSE` line — an explicit,
   unambiguous open event on the `wss://` URL.

(Aside: chrome-devtools MCP's `list_network_requests` — even filtered to
`resourceTypes: ["websocket"]` — never listed the `/ws` upgrade request
itself, only the plain HTTP/HTTPS asset and API requests. Given the two
positive checks above, I treat this as a limitation of that tool's Network
panel capture for WS upgrades in this environment, not evidence of a missing
connection.)

Screenshot: `.../screenshots/05-dashboard-ws-confirmed.png`.

### A cosmetic/documentation finding worth flagging (not fixed — out of scope for this test-only task)

While reading the dashboard's own copy to build the WS check, I found the
static frontend still describes the **pre-TLS** threat model verbatim in
three places:
- `crates/workbench-mesh/assets/command-center/app.js:131` — status bar:
  `"trusted LAN · plaintext HTTP"`
- `crates/workbench-mesh/assets/command-center/host.js:318` — Host tab note:
  `"local + trusted-LAN surface · plaintext HTTP with bearer tokens · no
  public exposure, no TLS — by design"`
- `crates/workbench-mesh/assets/command-center/data.js:229` — FAQ answer:
  `"No — LAN mode is plaintext HTTP with bearer-token auth, trusted-LAN
  only, by design. There's no TLS and no public exposure."`

This is now **factually stale**: lan mode has used TLS with certificate
pinning since Task 1 of this very plan, and the whole point of Tasks 1-14
was to add exactly the TLS layer this copy says doesn't exist. It's not a
security hole in the crypto (the actual bytes on the wire are correctly
TLS-encrypted per this task's own passing test), but it is user-facing copy
that actively contradicts the real security model, which could lead a user
to under- or over-trust the connection. I did not touch it — Task 15 is
explicitly test-only ("no new production code") — but I recommend a small
follow-up task to update this copy as part of, or right after, this plan's
Final Steps review.

## Cleanup

- Killed the manual-check `workbench-mesh serve` process
  (`kill $(cat .../server.pid)`), confirmed via `ps aux` no
  `workbench-mesh` process remains.
- Removed the temp project directory
  (`.../scratchpad/mesh-manual-check/project`); only the log file and
  screenshots (evidence) remain under scratch.
- Navigated the browser tab back to `about:blank` before killing the server.
- `git status --short` confirms only the two files this task is allowed to
  touch changed: `crates/workbench-mesh/src/server.rs` (this task) and this
  report. The pre-existing, out-of-scope
  `.superpowers/sdd/task-7-report.md` modification that was already present
  before this task started was explicitly called out as "leave those
  alone" and was left untouched and unstaged. `.playwright-mcp/` and
  `.workbench/` remain untracked and untouched, as instructed.

## Commit

Staged only `crates/workbench-mesh/src/server.rs` and this report — did
**not** stage `.superpowers/sdd/task-7-report.md`, `.playwright-mcp/`, or
`.workbench/`.

## Concerns / follow-ups for the record

1. **Stale `target/release/workbench-mesh` binary** (see Step 5 above) —
   not a code defect, but a real trap for anyone manually verifying this
   feature in this checkout without rebuilding first. Worth a note in
   `CONTRIBUTING.md` or the release runbook to always rebuild before a
   manual TLS/dashboard check.
2. **Stale "no TLS / plaintext HTTP" copy in the dashboard UI** (see above) —
   cosmetic/documentation drift, recommend a fast-follow task to update
   `app.js`, `host.js`, and `data.js` copy to reflect the TLS-pinned lan
   mode this plan just shipped.
3. **`run_in_background` Bash jobs were silently torn down mid-run** in this
   session when a coordinator message interrupted the turn — not a repo or
   test issue, but worth knowing if this happens again: re-running
   synchronously in the foreground resolved it cleanly with no other
   workaround needed.

Neither of these is a security gap in the wrong-fingerprint rejection this
task exists to prove — that guarantee held on the first try, unmodified,
exactly as tasks 1-11 promised.
