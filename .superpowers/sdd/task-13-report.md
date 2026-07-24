# Task 13 report — `scripts/mesh.sh` invite/connect/start wiring

Plan: `docs/superpowers/plans/2026-07-05-mesh-lan-tls-pinning.md`, Task 13.
Branch: `feat/mesh-lan-tls-pinning`, base commit `3da8fc1`.

**Note on this file's location:** `.superpowers/sdd/task-13-report.md` already
existed on disk with unrelated content — a report for a *different* "Task 13"
from a different plan (a dashboard minor-fixes batch: devices empty-state,
form ids, Ops centering, room-name guard, Docs keyboard access). That file
was untracked (`git ls-files` confirms — never committed) and matched by the
repo's blanket `.superpowers/` gitignore rule, so it was stale scratch
leftover, not committed history. Per this task's explicit instruction to
write the report to this exact path, I overwrote it with this task's report.

## Files changed

- `scripts/mesh.sh` — Steps 1–4 from the brief, plus one pre-existing bug fix
  found while building the mandatory Step 5 test (see "Deviation 2" below).
- `test/mesh-command-center.test.sh` — new Step 5 end-to-end section (see
  "Deviation 1" for why this file rather than the brief's two named
  candidates).
- `test/mesh-packaging.test.sh` — two pre-existing wrapper-level assertions
  updated to match this task's intentional behavior changes (bare-host
  connect syntax, new usage() text); see "Deviation 3".

## What changed, with final line numbers

Brief-cited ranges (131–152, 154–182, 404–436) matched the actual file
almost exactly; final numbers drifted by at most 1–2 lines because of the
edits themselves, noted below.

### 1. `usage()` connect line — `scripts/mesh.sh:28`

```
connect [HOST|URL] TOKEN [DEVICE] [--fingerprint sha256:HASH] [-y|--yes]
```
(was `connect [URL] TOKEN [DEVICE]`). The brief's Files list named
`usage() text` as in-scope but gave no literal snippet; I wrote this to
describe the actual new syntax Steps 1–3 implement.

### 2. `print_connect_commands` — `scripts/mesh.sh:131-153` (brief: 131-152)

Exactly the brief's Step 2 code: added a `fingerprint` second parameter,
builds `fp_flag=" --fingerprint sha256:$fingerprint"` when non-empty, and
switches the `connect`/`connect-host`/`connect-ip` lines to `https://` /
bare-IP-no-port for lan mode. Left the lan branch's final `connect-url:`
line using `metadata_url()` verbatim (still `http://`), exactly as the
brief's code block shows — see "Concerns" below for why that one line is
still not directly usable in lan mode.

### 3. `print_start_info` — `scripts/mesh.sh:156-183` (brief: 154-182)

Exactly the brief's Step 4 code: lan branch now prints
`Workbench mesh will listen on the local network, over TLS.` /
`Host: https://…` / `LAN IP: https://…` / `Local: https://127.0.0.1:$port`,
and drops the old hardcoded `Command center: http://127.0.0.1:$port` line
entirely (that line was always wrong in lan mode — it printed a bare HTTP
loopback URL even though lan mode is TLS-only). Local-mode branch untouched.

### 4. `invite)` — `scripts/mesh.sh:408-430` (brief: 404-422)

Exactly the brief's Step 1 code: after printing `url:`, reads
`tls_fingerprint` via `metadata_field`, and — only when present (i.e. lan
mode) — prints `Fingerprint code: NNN-NNN` via `"$BIN" fingerprint-code
"$fingerprint"`, then passes the fingerprint through to
`print_connect_commands`.

### 5. `connect)` — `scripts/mesh.sh:431-453` (brief: 423-436)

Exactly the brief's Step 3 code: `host_or_url` now matches bare host
(`^[A-Za-z0-9.-]+(:[0-9]+)?$`) or a full `https?://` URL; token/device
parsing shifted into an `extra=()` pass-through loop that recognizes
`--fingerprint VALUE` and `-y|--yes`, treating any other leftover token as
`device` (last one wins, matching the brief's literal loop).

### 6. `start)` `--port` double-flag bug — `scripts/mesh.sh:288-345` (not in brief's file list — see Deviation 2)

## Deviations from the brief (with reasoning)

**1. Test file: extended `test/mesh-command-center.test.sh`, not
`test/mesh-ops.test.sh` / `test/mesh-command-center.test.sh` (brief's named
candidates) via the grep it suggested, and not `test/mesh-remote-lan.test.sh`
(the closest thematic match).**

The brief's own suggested locator (`grep -rl "invite)\|connect)" test/*.sh`)
returns *zero* matches — those literal parenthesized case-labels only exist
inside `scripts/mesh.sh` itself, never in a test file, so the grep couldn't
have found either candidate the brief named. I checked all three real
candidates:
- `test/mesh-ops.test.sh` — no invite/connect/lan coverage at all (only
  room/message/ask/handoff/jobs/snapshot).
- `test/mesh-command-center.test.sh` — already in `test/all.sh`, already has
  invite-output and `start --bind lan|local` *validation* coverage
  (no real lan server), and already uses the repo's established
  per-scenario isolation pattern (`mkdir -p "$X/bin"; ln -sf "$BIN"
  "$X/bin/workbench-mesh"`) for exactly the reason I needed it: `mesh.sh`
  resolves its binary through `$CLAUDE_PLUGIN_ROOT/bin/workbench-mesh`, and
  this repo's `bin/workbench-mesh` is a dispatcher that prefers
  `target/release/workbench-mesh` when present — which in this checkout is
  a **stale build from 2026-07-05** that predates `fingerprint-code`/TLS
  entirely (`error: unrecognized subcommand 'fingerprint-code'`). Only the
  symlink-straight-to-`target/debug` pattern (already established in this
  file) sidesteps that trap.
- `test/mesh-remote-lan.test.sh` — the *thematically* closest existing file
  (host + join temp dirs, invite+connect via `mesh.sh`, credential + message
  assertions) and, by its own `git log`, predates the TLS pinning plan
  (added 2026-07-01, before the plan's `2026-07-05` date). I ran it
  standalone on the **unmodified base commit** (confirmed via `git stash`)
  and it currently **fails 8 of its checks** — it uses the *same* project
  directory for both "host" and "joiner" (only `WORKBENCH_HOME` differs),
  which trips a guard added by a later hardening task
  (`accept_remote_invite` refuses to connect into a directory that already
  hosts its own server). It is also **not wired into `test/all.sh` at all**
  (confirmed by reading `test/all.sh`'s test list and `.github/workflows/ci.yml`
  — only `test/all.sh` runs in CI, and this file isn't in it). Extending an
  already-broken, already-unregistered file would not satisfy "run
  `bash test/all.sh` — must be fully green" without also fixing an unrelated
  pre-existing regression and registering the file, both outside this
  task's declared scope (`scripts/mesh.sh` + `usage()` + one of two named
  test files). I left `mesh-remote-lan.test.sh` untouched and flag its
  brokenness under "Concerns" below.

Given the above, I extended `test/mesh-command-center.test.sh` — one of the
brief's two named candidates, already registered and green — with a new
`== full TLS lan enrollment via scripts/mesh.sh: bare host + --fingerprint +
--yes (Task 13) ==` section (lines ~340-390) implementing all 5 of Step 5's
bullets: real `start --lan --port 0` through `mesh.sh`, real `invite` with
fingerprint/code extraction, real `connect <bare-host> <token> <device>
--fingerprint sha256:... --yes` from a second, independent project
directory, credential-file assertion, and a message round-trip verified via
the host's own event log.

**2. Fixed a pre-existing, unrelated bug in `start)`'s `--port` handling
(`scripts/mesh.sh:288-345`, not in the brief's file list).**

Writing Step 5's test literally (`mesh.sh start --lan --port 0`) crashed
every time with:
```
error: the argument '--port <PORT>' cannot be used multiple times
```
`--port)`'s case body did `pass+=(--port "$2")` *and* the post-loop
`[ "$mode" = lan ] && [ "$port" = 0 ]` default block did `pass+=(--port
"$port")` again — so `--lan --port 0` appended `--port` to the passthrough
array twice. I confirmed this predates my changes with `git stash` +
running the exact same command against the unmodified base commit — same
crash. Since the brief's Step 5 bullet 1 is explicit
(`bash scripts/mesh.sh start --lan --port 0 …`) and this bug made that
literal invocation impossible for *any* caller, not just my test, I fixed
it: `--port)`'s case now only sets `port="$2"` (no longer appends to
`pass`), and a single `pass+=(--port "$port")` runs once, after the
lan-mode default resolves `$port`, using the final value either way. No
other `start)` behavior changes; verified no test asserts on `--port`'s
absence when unset (grepped all `start …--port` usages across `test/*.sh`).

**3. Updated two pre-existing assertions in `test/mesh-packaging.test.sh`**
(discovered only by running `bash test/all.sh`, per the task's "diagnose
and fix, don't assume it's environmental" instruction):

- `"wrapper connect local token accepts invite"` called
  `run_wrapper connect local-token laptop`. `local-token` (letters + hyphen,
  no underscore) now matches the new bare-host regex
  (`^[A-Za-z0-9.-]+(:[0-9]+)?$`), so `mesh.sh` started treating it as
  `--url local-token` instead of a bare `--token` — this is real, correct
  new behavior for anything shaped like a hostname, and real invite tokens
  (`wb_invite_<random>`, per `auth::create_invite`) always contain an
  underscore and can never collide. I updated the fixture token to
  `wb_invite_local-token` (matches the real shape) rather than changing the
  regex — the regex is the brief's literal, exact code.
- `"wrapper help advertises URL connect syntax"` asserted the literal old
  `connect [URL] TOKEN [DEVICE]` string; updated to assert the new
  `connect [HOST|URL] TOKEN [DEVICE] [--fingerprint sha256:HASH]
  [-y|--yes]` text, matching item 1 above.

No other test files needed changes; `grep -rn "mesh.sh connect\|/workbench:mesh
connect"` across `docs/`, `commands/mesh.md`, `skills/mesh/SKILL.md`,
`README.md` shows several docs still describe the old
`connect [URL] TOKEN [DEVICE]` syntax — none of those files were in the
brief's scope for this task, so I left them untouched; flagging as a
possible follow-up.

## Automated verification

**`bash test/mesh-command-center.test.sh` (standalone, run twice for
flake-check):**
```
== full TLS lan enrollment via scripts/mesh.sh: bare host + --fingerprint + --yes (Task 13) ==
ok: lan start banner prints https, not the old bare loopback command-center line
ok: lan invite prints a human fingerprint code
ok: lan invite connect line uses https, not http
ok: lan invite captured a token
ok: lan invite captured a --fingerprint sha256:... value
ok: bare-host connect with --fingerprint/--yes pass-through succeeds
ok: bare-host connect persists the joining credential outside the repo
ok: joiner message command succeeds over the pinned TLS connection
ok: joiner message round-trips to the host event log
PASS: mesh-command-center
```
184 `ok:` lines, 0 `FAIL` lines, both runs.

**`bash test/mesh-packaging.test.sh` (standalone, after the fixture fix):**
`PASS: mesh-packaging` — all checks, including the two updated ones
(`wrapper connect local token accepts invite`, `wrapper help advertises
host/URL connect syntax with fingerprint/yes flags`).

**`bash test/all.sh` (repo root):**
- First run (before the `mesh-packaging.test.sh` fixture fixes above):
  `SOME TESTS FAILED` — exactly the 2 `mesh-packaging` failures described in
  Deviation 3, nothing else.
- Second run (after the fixes): `ALL TESTS PASS` — 69 `PASS:` lines, 0
  `FAIL` lines, exit 0.

**`cargo test -p workbench-mesh`:**
```
test result: ok. 152 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.70s   (src/lib.rs)
test result: ok. 5 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s      (src/main.rs)
test result: ok. 0 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s      (doc-tests)
```
No `.rs` files were touched by this task (confirmed via `git status` /
`git diff --stat` before and after) — this run is a pure regression check,
fully green, matching the base commit's already-green state.

## Concerns for follow-up (not fixed here — out of this task's scope)

1. **`test/mesh-remote-lan.test.sh` is currently broken and not wired into
   `test/all.sh`.** Pre-existing on the unmodified base commit (confirmed via
   `git stash`), unrelated to this task. It uses one project directory for
   both "host" and "joiner" roles, which a later hardening task's
   "already hosts its own mesh server" guard now rejects; 8 of its ~15
   checks fail as a direct result. It should either be rewritten to use two
   independent project directories (like this task's new
   `mesh-command-center.test.sh` section does) and registered in
   `test/all.sh`, or removed if superseded. Flagging rather than fixing
   since it's unrelated to Task 13's scope and touching it risked scope
   creep beyond what was asked.
2. **`print_connect_commands`'s lan-mode `connect-url:` line still prints
   `http://`.** Per the brief's exact Step 2 code, only the `connect`,
   `connect-host`, and `connect-ip` lines were switched to `https://`/bare
   IP; the final `connect-url:` line still calls the unmodified
   `metadata_url()` helper, which unconditionally formats `http://%s:%s`
   regardless of mode. In lan mode this prints something like
   `connect-url: /workbench:mesh connect http://<host>:<port> <token>
   --fingerprint sha256:...` — an `http://` URL that the Rust client will
   actually reject (`remote mesh connections require https`). The other
   three printed forms (mdns, hostname, raw IP) are all correct and usable.
   This is pre-existing behavior kept intentionally as the brief specified
   it verbatim; flagging in case a follow-up task wants `metadata_url()`
   itself made mode-aware.
3. Several docs (`docs/commands.md`, `docs/concepts.md`,
   `docs/configuration.md`, `skills/mesh/SKILL.md`, `commands/mesh.md`,
   `README.md`) still describe the old `connect [URL] TOKEN [DEVICE]`
   syntax without `--fingerprint`. None were in this task's file scope;
   flagging for a documentation follow-up.

## Commit

Files staged: `scripts/mesh.sh`, `test/mesh-command-center.test.sh`,
`test/mesh-packaging.test.sh`, and this report file (force-added — the
`.superpowers/` directory is gitignored repo-wide, matching the existing
precedent of `.superpowers/sdd/task-7-report.md`, which is tracked despite
the same blanket ignore rule).

Did **not** touch or stage `.superpowers/sdd/task-7-report.md` (pre-existing
unrelated modification, explicitly called out as out of scope) or the
untracked `.playwright-mcp/`/`.workbench/` directories.
