# Mesh Pre-Release Audit — Blocker Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix all 7 blockers found by the 2026-07-04 pre-release audit (docs/superpowers/specs referenced inline per task) before the mesh subsystem can ship.

**Architecture:** Each task is an independent, narrowly-scoped bug fix — no shared design decisions across tasks, no new abstractions. Fixes span `scripts/mesh.sh` (bash), `crates/workbench-mesh/src/{auth,client}.rs` (Rust), `crates/workbench-mesh/assets/command-center/{live,bench}.js` (vanilla JS), and `crates/workbench-mesh/assets/command-center/{style,style-surfaces}.css`.

**Tech Stack:** Bash, Rust (existing crate conventions), vanilla JS/CSS (no framework, no build step — same constraints as the rest of this dashboard).

## Global Constraints

- Every fix must be independently verifiable — no fix should require another task to be "done" to test it.
- Bash fixes: run `bash test/mesh-command-center.test.sh` and `bash test/all.sh` after each change — these are the only automated safety nets for `scripts/mesh.sh`.
- Rust fixes: run `cargo test -p workbench-mesh` after each change; no new `unwrap()` outside tests; match existing `anyhow::Result`/`.context()` conventions.
- JS/CSS fixes: no JS test framework exists — verification is the shell suite plus manual/browser reading. State clearly in your report if you could not do live browser verification.
- Do not fix Important or Minor findings in these tasks unless a task explicitly says to — stay scoped to the named blocker.

---

## File Structure

- `scripts/mesh.sh` — Tasks 1, 3, 6 (flag pre-scanner, connect command printing, activity arg forwarding)
- `crates/workbench-mesh/src/client.rs` — Task 2 (connect metadata clobber guard)
- `crates/workbench-mesh/src/auth.rs` — Task 3 (device name placeholder rejection)
- `crates/workbench-mesh/assets/command-center/live.js` — Task 4 (team/repo:workbench room mismatch)
- `crates/workbench-mesh/assets/command-center/bench.js` — Task 5 (@-mention exact-match priority)
- `crates/workbench-mesh/assets/command-center/style.css`, `style-surfaces.css` — Task 7 (mobile breakpoint)

---

### Task 1: `mesh.sh` — stop the global flag scanner from eating free-text message content

**Files:**
- Modify: `scripts/mesh.sh:194-239` (the global `--as`/`--platform`/`--capability`/`--provider`/`--model` pre-scan block)

**Interfaces:**
- Consumes: nothing new.
- Produces: same `AS_ARGS`/`PLATFORM_ARGS`/`CAP_ARGS`/`PROVIDER_ARGS`/`MODEL_ARGS` arrays every downstream `case` branch already reads — signature unchanged, only the extraction algorithm changes.

**The bug:** the scanner walks every argument front-to-back and treats a literal `--as`/`--platform`/`--capability`/`--provider`/`--model` token *anywhere* as a real flag — including inside unquoted free-text message/question/doing content. `mesh.sh message audit-room-1 please use --as flag correctly` silently becomes `from=flag`, text `"please use correctly"`.

**The fix (corrected — an earlier draft of this task was found wrong by a live test run and must NOT be used):** a pure trailing-scan applied to *every* operation breaks `listen-wait`'s fallback path, which `exec`s into `inbox --as ACTOR --wait` — since `--wait` trails `--as ACTOR` there, a trailing-only scan stops at `--wait` (not a recognized flag) before ever reaching `--as` further left, and the actor is never extracted. Confirmed live: `bash scripts/mesh.sh listen-wait --as fallback-actor` regressed to `mesh: inbox requires --as ACTOR` under a blanket trailing-scan.

Only `message`, `ask`, and `doing` actually join their remaining args into **unbounded free text** — every other operation (`inbox`, `listen-wait`, `room`, `watch`, `handoff`, `availability`, `tail`, `activity`, `start`) takes a bounded number of positional args plus these flags in any relative order, so front-to-back scanning is safe and necessary for them (it's what correctly handles `--as X --wait` regardless of order). Branch the pre-scan on `$cmd` (already known before the scanner runs, since `cmd="${1:-}"` + `shift` happen first): trailing-scan for `message`/`ask`/`doing` only, the original front-to-back scan for everything else.

- [ ] **Step 1: Write the failing test**

Add to `test/mesh-command-center.test.sh`, near the existing messaging checks (search for `chk "message` to find the right neighborhood):

```bash
echo "== flag pre-scan does not corrupt free-text message content (blocker fix) =="
FLAG_MSG_OUT="$("$BIN" event list --target "$TMP" --home "$HOME_TMP" --since 0 2>/dev/null | tail -1)"
"$BIN" auth check --target "$TMP" --home "$HOME_TMP" --token "$TOKEN" >/dev/null 2>&1 || true
bash "$HERE/scripts/mesh.sh" message team "please use --as flag correctly" >/dev/null 2>&1 || true
FLAG_MSG_SEQ="$(curl -fsS "http://127.0.0.1:$PORT/api/events?since=0" -H "Authorization: Bearer $TOKEN" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for e in data['events']:
    if e.get('type') == 'message.sent' and 'please use' in e.get('payload', {}).get('text', ''):
        print(e['payload']['text'])
        print(e['from'])
")"
chk "free-text message with an embedded --as token is preserved in full" "printf '%s\n' \"\$FLAG_MSG_SEQ\" | head -1 | grep -qx 'please use --as flag correctly'"
chk "sender identity is not spoofed by the embedded token" "printf '%s\n' \"\$FLAG_MSG_SEQ\" | sed -n 2p | grep -q '^session:lead$\|^forge-lead$'"
```

Adapt the exact `chk`/curl/variable names to whatever this test file's established pattern is at the point you insert this (re-read the file first — it may not have `$TOKEN`/`$PORT` in scope at every point; place this block after the server is up and `$PORT`/`$TOKEN` are already set, matching neighboring checks). The precise sender-identity assertion should match whatever `--as`/default actor this test file uses elsewhere for CLI-posted messages (it might be `forge-lead` per the file's `--as forge-lead` server start, not `session:lead` — check and use the real one).

- [ ] **Step 2: Run test to verify it fails**

Run: `bash test/mesh-command-center.test.sh 2>&1 | grep -A2 "embedded --as"`
Expected: FAIL — the current scanner truncates the message and spoofs the sender to `flag`.

- [ ] **Step 3: Replace the flag pre-scan with a trailing-only scan**

Replace lines 194-239 of `scripts/mesh.sh` (the whole comment block through `fi`) with:

```bash
# Pull `--as ACTOR`, `--platform NAME`, repeatable `--capability VALUE`,
# `--provider NAME`, `--model NAME` out of the remaining args.
#
# message/ask/doing join their remaining args into UNBOUNDED free-text
# message/question/doing content, so for those three operations only, scan
# for these flags from the END of the argument list backward, stripping a
# trailing run of recognized `flag value` pairs — never from the middle.
# Every documented usage of these flags on these three ops has them trail
# the free text (e.g. `message TARGET TEXT... [--as ACTOR]`), so this means
# a flag-shaped word buried INSIDE a message (e.g. "please use --as flag
# correctly") is never mistaken for a real flag; only a genuine trailing
# flag (or a message whose literal last two words happen to collide) can
# still match — a much narrower window than the bug this replaces.
#
# Every other operation takes a bounded number of positional args plus
# these flags in any relative order (e.g. `inbox --as ACTOR --wait`, where
# --wait trails --as) — for those, front-to-back scanning is safe (there is
# no free-text tail to protect) and must be preserved, since a trailing-only
# scan would stop at --wait before ever reaching --as further left.
AS_ARGS=()
PLATFORM_ARGS=()
CAP_ARGS=()
PROVIDER_ARGS=()
MODEL_ARGS=()
case "$cmd" in
  message|ask|doing)
    if [ "$#" -gt 0 ]; then
      rest=("$@")
      while [ "${#rest[@]}" -ge 2 ]; do
        last=$((${#rest[@]} - 1))
        flag="${rest[$((last - 1))]}"
        value="${rest[$last]}"
        case "$flag" in
          --as) AS_ARGS=(--as "$value") ;;
          --platform) PLATFORM_ARGS=(--platform "$value") ;;
          --capability) CAP_ARGS=(--capability "$value" "${CAP_ARGS[@]}") ;;
          --provider) PROVIDER_ARGS=(--provider "$value") ;;
          --model) MODEL_ARGS=(--model "$value") ;;
          *) break ;;
        esac
        keep=$((${#rest[@]} - 2))
        if [ "$keep" -gt 0 ]; then
          rest=("${rest[@]:0:$keep}")
        else
          rest=()
        fi
      done
      set -- "${rest[@]}"
    fi
    ;;
  *)
    if [ "$#" -gt 0 ]; then
      rest=()
      i=1
      while [ "$i" -le "$#" ]; do
        arg="${!i}"
        case "$arg" in
          --as)
            i=$((i + 1))
            AS_ARGS=(--as "${!i:-}")
            ;;
          --platform)
            i=$((i + 1))
            PLATFORM_ARGS=(--platform "${!i:-}")
            ;;
          --capability)
            i=$((i + 1))
            CAP_ARGS+=(--capability "${!i:-}")
            ;;
          --provider)
            i=$((i + 1))
            PROVIDER_ARGS=(--provider "${!i:-}")
            ;;
          --model)
            i=$((i + 1))
            MODEL_ARGS=(--model "${!i:-}")
            ;;
          *)
            rest+=("$arg")
            ;;
        esac
        i=$((i + 1))
      done
      set -- "${rest[@]}"
    fi
    ;;
esac
```

This is operation-aware: trailing-scan for `message`/`ask`/`doing` (protects free text), front-to-back for everything else (preserves `inbox --as ACTOR --wait`-style ordering-independent flag parsing). Also add a regression check for the `listen-wait` fallback case specifically in Step 4 below — it's the exact scenario the earlier flawed draft broke.

- [ ] **Step 4: Run the new test to verify it passes, then the full suite**

Run: `bash test/mesh-command-center.test.sh 2>&1 | tail -60`
Expected: PASS — including the new check, and every pre-existing check (in particular any test that relies on trailing `--as ACTOR` for `message`/`ask`/`doing`/`room`/`watch`/`availability`/`start` must still pass, since trailing extraction is exactly what those rely on).

Run: `bash test/all.sh 2>&1 | tail -80`
Expected: PASS — full existing suite, no regression.

- [ ] **Step 5: Self-review a known limitation**

Confirm in your report: this fix does not make flag-vs-free-text parsing perfect (a message whose literal last two words happen to be e.g. `for --as` would still be misparsed) — this is a known, accepted, far-narrower residual case than the bug being fixed, not a new gap to solve here.

- [ ] **Step 6: Commit**

```bash
git add scripts/mesh.sh test/mesh-command-center.test.sh
git commit -m "fix(mesh): scan --as/--platform/etc flags from the end, not the whole arg list"
```

---

### Task 2: `connect` must refuse to clobber a project's own running server metadata

**Files:**
- Modify: `crates/workbench-mesh/src/client.rs` (`accept_remote_invite`, ~line 163)
- Test: `crates/workbench-mesh/src/client.rs` (inline `#[cfg(test)]`)

**Interfaces:**
- Consumes: `server::read_server_metadata(&Path) -> Result<ServerMetadata>` (already exists).
- Produces: `accept_remote_invite` now returns an `Err` early (before any network call or file write) when the target project already has its own local/lan server metadata on disk.

**The bug:** `accept_remote_invite` calls `write_server_metadata(&project_root, &metadata)` unconditionally with the *remote* server's metadata — silently overwriting an existing `local`/`lan` `server.json` for a server that's actually still hosting from that same directory. This wipes `local_token` and flips `mode` to `remote`, breaking `open`/`status`/`who` until the server is restarted.

**The fix:** before doing anything else in `accept_remote_invite`, check whether `project_root` already has server metadata whose `mode` is `local` or `lan` (i.e., this directory already considers itself a host) — if so, refuse with a clear error. A directory that already hosts its own server has no business accepting a *remote* invite pointed at a different server; that combination only makes sense from a client-only checkout.

- [ ] **Step 1: Write the failing test**

Add to `client.rs`'s test module:

```rust
    #[tokio::test]
    async fn accept_remote_invite_refuses_when_project_already_hosts_a_local_server() {
        let project = TempDir::new().unwrap();
        let home = TempDir::new().unwrap();
        write_project_config(project.path(), "Mesh Client");
        // Simulate an already-running local server by writing its metadata directly —
        // this is exactly what `serve()` does on startup.
        crate::server::write_server_metadata(
            project.path(),
            &crate::server::ServerMetadata {
                mode: "local".to_string(),
                host: "127.0.0.1".to_string(),
                port: 44444,
                hostname: "test-host".to_string(),
                mdns: "test-host.local".to_string(),
                lan_ips: vec![],
                local_token: "real-local-token".to_string(),
                started_by: "test-lead".to_string(),
                started_at: "2026-07-04T00:00:00Z".to_string(),
            },
        )
        .unwrap();

        let err = super::accept_remote_invite(
            project.path().to_path_buf(),
            Some(home.path().to_path_buf()),
            "http://127.0.0.1:9999".to_string(),
            "wb_invite_fake".to_string(),
            "some-device".to_string(),
        )
        .await
        .unwrap_err();

        assert!(
            err.to_string().contains("already hosts its own"),
            "unexpected error: {err:#}"
        );

        // The original local metadata must be completely untouched.
        let after = crate::server::read_server_metadata(project.path()).unwrap();
        assert_eq!(after.mode, "local");
        assert_eq!(after.local_token, "real-local-token");
    }
```

Check whether `write_project_config` already exists in this test module (it's used elsewhere in client.rs's tests per the existing suite) — reuse it, don't duplicate it.

- [ ] **Step 2: Run test to verify it fails**

Run: `cargo test -p workbench-mesh client::tests::accept_remote_invite_refuses_when_project_already_hosts_a_local_server 2>&1 | tail -30`
Expected: FAIL — today's code overwrites the metadata and returns `Ok(())` (or fails later for an unrelated network reason against the fake URL, not the guard we're adding).

- [ ] **Step 3: Add the guard**

At the very top of `accept_remote_invite`'s body (`client.rs`, before `let metadata = remote_metadata_from_url(&url)?;`):

```rust
pub async fn accept_remote_invite(
    project_root: PathBuf,
    home: Option<PathBuf>,
    url: String,
    token: String,
    device: String,
) -> Result<()> {
    if let Ok(existing) = read_server_metadata(&project_root) {
        if existing.mode == "local" || existing.mode == "lan" {
            anyhow::bail!(
                "{} already hosts its own mesh server (mode: {}) — connect refuses to overwrite its metadata. \
                 Run this from a different project checkout, or stop the local server first if it's actually abandoned.",
                project_root.display(),
                existing.mode
            );
        }
    }
    let metadata = remote_metadata_from_url(&url)?;
    // ... rest unchanged
```

`read_server_metadata` is already imported in this file (it's used by `status`/`who`/etc. elsewhere in client.rs) — confirm the import exists; if it's only `use crate::server::{read_server_metadata, write_server_metadata, ServerMetadata};` already present, no import change needed.

- [ ] **Step 4: Run tests to verify they pass**

Run: `cargo test -p workbench-mesh 2>&1 | tail -40`
Expected: PASS — the new test, plus every existing `accept_remote_invite`/`connect` test (there are existing tests for the happy path and project-mismatch path elsewhere in this file and in server.rs — confirm none of them start from a project directory that already has local/lan metadata written, which would now correctly start failing at this new guard; if any do, that's a sign that test needs its own project directory rather than a change to this fix).

- [ ] **Step 5: Commit**

```bash
git add crates/workbench-mesh/src/client.rs
git commit -m "fix(mesh): connect refuses to clobber a project's own running server metadata"
```

---

### Task 3: Invite's printed connect command must be genuinely copy-pasteable

**Files:**
- Modify: `scripts/mesh.sh` (`print_connect_commands`, lines 127-148)
- Modify: `crates/workbench-mesh/src/auth.rs` (`sanitize_device_identifier`, ~line 570)
- Test: `test/mesh-command-center.test.sh`, `crates/workbench-mesh/src/auth.rs` inline tests

**Interfaces:**
- Consumes: nothing new.
- Produces: `print_connect_commands` no longer emits a `<device>` placeholder; `sanitize_device_identifier` now rejects any raw input containing `<`/`>` before sanitizing, as defense-in-depth against any *other* place a placeholder-looking name could still arrive.

**The bug:** every line `print_connect_commands` prints ends in a literal `<device>`. Pasted verbatim, `sanitize_name` strips `<`/`>` to `-` and trims, so `<device>` silently becomes the real device name `device` — no error. A second paste creates a second device also named `device`, silently overwriting the first one's credential file.

**The fix (two parts):**
1. Stop printing the device positional at all — `mesh.sh connect`'s own case already defaults `device="${2:-$(host_name)}"` when the third argument is omitted, so dropping it from the printed line makes the command truly copy-paste-and-run.
2. Defense-in-depth: reject any raw device name containing `<` or `>` before it ever reaches `sanitize_name`, in case a placeholder-looking string arrives some other way (an older cached doc, a user typing it by habit).

- [ ] **Step 1: Write the failing tests**

For the auth.rs fix, add to its test module:

```rust
    #[test]
    fn sanitize_device_identifier_rejects_unresolved_placeholder_brackets() {
        let err = super::sanitize_device_identifier("<device>").unwrap_err();
        assert!(
            err.to_string().contains("placeholder"),
            "unexpected error: {err:#}"
        );
        let err = super::sanitize_device_identifier("my<device>").unwrap_err();
        assert!(err.to_string().contains("placeholder"));
    }

    #[test]
    fn sanitize_device_identifier_still_accepts_real_names() {
        assert_eq!(super::sanitize_device_identifier("macbook").unwrap(), "macbook");
        assert_eq!(super::sanitize_device_identifier("Guus's MacBook").unwrap(), "guus-s-macbook");
    }
```

For the mesh.sh fix, add to `test/mesh-command-center.test.sh` near the invite-flow checks:

```bash
echo "== invite connect command is copy-pasteable (no <device> placeholder) =="
INVITE_TEXT="$(bash "$HERE/scripts/mesh.sh" invite --role worker --ttl-seconds 900 2>&1)"
chk "printed connect command contains no literal <device> placeholder" "! printf '%s\n' \"\$INVITE_TEXT\" | grep -q '<device>'"
```

Adapt to reuse whatever env/target this test file already established for its own invite checks (same project/home/port as neighboring lines).

- [ ] **Step 2: Run tests to verify they fail**

Run: `cargo test -p workbench-mesh auth::tests::sanitize_device_identifier 2>&1 | tail -30`
Expected: FAIL — no placeholder rejection exists yet.

Run: `bash test/mesh-command-center.test.sh 2>&1 | grep -A2 "no literal"`
Expected: FAIL — `<device>` is still printed today.

- [ ] **Step 3: Fix `sanitize_device_identifier`**

```rust
fn sanitize_device_identifier(value: &str) -> Result<String> {
    if value.trim().is_empty() {
        bail!("device name is required");
    }
    if value.contains('<') || value.contains('>') {
        bail!(
            "device name '{value}' looks like an unresolved <device> placeholder — \
             replace it with a real device name"
        );
    }
    let sanitized = sanitize_name(value);
    if sanitized == "project" && !value.chars().any(|ch| ch.is_ascii_alphanumeric()) {
        bail!("device name is invalid");
    }
    Ok(sanitized)
}
```

- [ ] **Step 4: Fix `print_connect_commands` to omit the device positional**

Replace every `printf '... connect %s %s <device>\n' ...` line in `print_connect_commands` (scripts/mesh.sh lines 127-148) to drop the trailing `<device>` and its preceding space:

```bash
print_connect_commands() {
  local token="$1" mode port host mdns ip url
  port="$(metadata_port || true)"
  [ -n "$port" ] || return 0
  mode="$(metadata_field mode || true)"
  if [ "$mode" != "lan" ]; then
    if url="$(metadata_url)"; then
      printf 'connect-url: /workbench:mesh connect %s %s\n' "$url" "$token"
    fi
    return 0
  fi
  host="$(metadata_field hostname || true)"
  mdns="$(metadata_field mdns || true)"
  [ -n "$mdns" ] && printf 'connect: /workbench:mesh connect http://%s:%s %s\n' "$mdns" "$port" "$token"
  [ -n "$host" ] && [ "$host" != "$mdns" ] && printf 'connect-host: /workbench:mesh connect http://%s:%s %s\n' "$host" "$port" "$token"
  for ip in $(metadata_lan_ips || true); do
    [ -n "$ip" ] && printf 'connect-ip: /workbench:mesh connect http://%s:%s %s\n' "$ip" "$port" "$token"
  done
  if url="$(metadata_url)"; then
    printf 'connect-url: /workbench:mesh connect %s %s\n' "$url" "$token"
  fi
}
```

(Every `printf` format string loses its trailing ` <device>` and the caller's device-value arg — confirm each line's arg count still matches its `%s` count after the edit.)

- [ ] **Step 5: Run tests to verify they pass**

Run: `cargo test -p workbench-mesh 2>&1 | tail -40`
Run: `bash test/mesh-command-center.test.sh 2>&1 | tail -60`
Run: `bash test/all.sh 2>&1 | tail -80`
Expected: PASS on all three — including any pre-existing test that may have asserted the OLD `<device>`-containing output (if one exists, it must be updated to match the new no-placeholder output, not treated as a regression).

- [ ] **Step 6: Commit**

```bash
git add scripts/mesh.sh crates/workbench-mesh/src/auth.rs test/mesh-command-center.test.sh
git commit -m "fix(mesh): invite prints a copy-pasteable connect command, reject placeholder device names"
```

---

### Task 4: Dashboard-composed "team" messages must reach other live viewers

**Files:**
- Modify: `crates/workbench-mesh/assets/command-center/live.js` (`WB.api.sendChat`, ~line 419)

**Interfaces:**
- Consumes: nothing new.
- Produces: `sendChat` posts to `m.room` directly, matching what `defaultRooms()` already subscribes to and what the CLI's `mesh.sh message team ...` already posts to.

**The bug:** `defaultRooms()` subscribes to the literal room `team`. But `sendChat` translates `m.room === 'team' ? 'repo:workbench' : m.room` before posting — so a dashboard-composed "team" message actually lands in `repo:workbench`, a room nobody's default subscription list includes unless it happens to already be in loaded history. The CLI's `mesh.sh message team ...` posts to room `team` literally (confirmed: `room_for_target` only special-cases `session:`/`actor:`-prefixed targets, so `team` passes through unchanged) — so `team` is already the real, working, CLI-established broadcast room name; the dashboard's translation to `repo:workbench` is the actual bug.

- [ ] **Step 1: Read the current code**

Read `live.js`'s `sendChat` function to confirm it still reads:

```javascript
    sendChat(m) {
      pendingSelf.push(m.text);
      const type = m.kind === 'ask' ? 'message.request_status' : m.kind === 'handoff' ? 'task.handoff' : 'message.sent';
      const payload = m.kind === 'handoff' ? { task_id: m.text } : { text: m.text };
      return post(type, m.room === 'team' ? 'repo:workbench' : m.room, payload, m.to || undefined).then((data) => {
        ...
```

If the surrounding code has drifted since this plan was written (later tasks in this session may have touched it), adapt the fix below to the actual current shape — the core change is always: stop translating `'team'` to `'repo:workbench'`.

- [ ] **Step 2: Manual verification baseline**

Run: `bash test/mesh-command-center.test.sh 2>&1 | tail -40`
Expected: PASS (current baseline before this fix).

- [ ] **Step 3: Remove the translation**

```javascript
    sendChat(m) {
      pendingSelf.push(m.text);
      const type = m.kind === 'ask' ? 'message.request_status' : m.kind === 'handoff' ? 'task.handoff' : 'message.sent';
      const payload = m.kind === 'handoff' ? { task_id: m.text } : { text: m.text };
      return post(type, m.room, payload, m.to || undefined).then((data) => {
        ...
```

(Only the `post(...)` call's second argument changes — from the ternary to bare `m.room`. Everything else in the function is unchanged.)

- [ ] **Step 4: Manual verification**

Run: `bash test/mesh-command-center.test.sh 2>&1 | tail -40`
Expected: PASS — no existing check should depend on the `repo:workbench` translation (grep the test file for `repo:workbench` first to confirm; if a check does assert on it, that check was validating the bug and must be corrected to expect room `team` instead).

If you can start a real mesh server and open two dashboard tabs (or one tab plus a second WS client), confirm live: a message composed under the "team"/"all" filter in tab A now appears live in tab B without a reload. If you cannot drive two live browser sessions, say so plainly in your report — this is a one-line, low-risk change and the shell suite plus code-reading is an acceptable bar if live verification isn't possible in your environment.

- [ ] **Step 5: Commit**

```bash
git add crates/workbench-mesh/assets/command-center/live.js
git commit -m "fix(mesh): dashboard team messages post to room 'team', matching CLI and subscriptions"
```

---

### Task 5: @-mention must prefer an exact actor match over a prefix match

**Files:**
- Modify: `crates/workbench-mesh/assets/command-center/bench.js` (`routeFor`, ~line 129)

**Interfaces:**
- Consumes: nothing new.
- Produces: same `routeFor(text) -> {to: id} | {via: id|null}` return shape — only the actor-resolution logic inside changes.

**The bug:** `WB.AGENTS.find((x) => x.id === hit[1] || x.id.startsWith(hit[1]))` stops at the first array element satisfying *either* condition — so if an agent with `id` `alice-lead` appears before `alice` in `WB.AGENTS`, typing `@alice` matches `alice-lead`'s `startsWith` check first and returns it, never reaching the real exact match later in the array.

- [ ] **Step 1: Read the current code**

Confirm `routeFor`'s current body (re-read the file first — do not assume the line number is still exact after prior sessions' edits):

```javascript
  function routeFor(text) {
    const hit = text.match(/@([\w-]+)/);
    if (hit) {
      const a = WB.AGENTS.find((x) => x.id === hit[1] || x.id.startsWith(hit[1]));
      if (a) return { to: a.id };
    }
    const host = WB.AGENTS.find((a) => a.isHostSession);
    const hostLive = WB.state.hostState === 'healthy';
    return { via: hostLive && host ? host.id : null };
  }
```

- [ ] **Step 2: Manual verification baseline**

Run: `bash test/mesh-command-center.test.sh 2>&1 | tail -40`
Expected: PASS (baseline).

- [ ] **Step 3: Check exact match across the whole array first**

```javascript
  function routeFor(text) {
    const hit = text.match(/@([\w-]+)/);
    if (hit) {
      const exact = WB.AGENTS.find((x) => x.id === hit[1]);
      const a = exact || WB.AGENTS.find((x) => x.id.startsWith(hit[1]));
      if (a) return { to: a.id };
    }
    const host = WB.AGENTS.find((a) => a.isHostSession);
    const hostLive = WB.state.hostState === 'healthy';
    return { via: hostLive && host ? host.id : null };
  }
```

This guarantees an exact `id` match anywhere in `WB.AGENTS` always wins over a prefix match anywhere else, regardless of array order. A prefix match is still used as the existing autocomplete-style fallback when no agent has that exact id.

- [ ] **Step 4: Manual verification**

Run: `bash test/mesh-command-center.test.sh 2>&1 | tail -40`
Expected: PASS.

If you can seed two actors where one id is a prefix of the other (e.g. `alice` and `alice-lead`, in that array-insertion order so the bug would have triggered) and drive the composer live, confirm `@alice` now resolves to `alice` and `@alice-lead` still resolves to `alice-lead`. If you cannot drive a live browser, verify by reading the fixed logic carefully instead and say so in your report.

- [ ] **Step 5: Commit**

```bash
git add crates/workbench-mesh/assets/command-center/bench.js
git commit -m "fix(mesh): @-mention prefers an exact actor match over a prefix match"
```

---

### Task 6: `mesh.sh activity` must forward all its arguments, not just the state word

**Files:**
- Modify: `scripts/mesh.sh` (`activity)` case, lines 436-439)

**Interfaces:**
- Consumes: nothing new — the binary's `activity` subcommand already accepts `--ack-of` (built earlier this session) and already rejects unknown args via clap.
- Produces: `mesh.sh activity STATE --ack-of N` now actually reaches the binary instead of silently dropping `--ack-of`.

**The bug:** `exec "$BIN" activity "${PROJECT_ARGS[@]}" "$1" "${AS_ARGS[@]}"` only ever forwards the first positional arg (`$1`, the state word) plus `--as` — any other argument, including `--ack-of N`, is silently discarded. `mesh.sh activity reading --ack-of 5` returns success with a seq number, but the receipt is never actually created. `availability`'s case (line 424-426) correctly forwards `"$@"` — `activity` never got the same treatment.

- [ ] **Step 1: Write the failing test**

Add to `test/mesh-command-center.test.sh` near the activity checks:

```bash
echo "== activity forwards --ack-of through to the binary (blocker fix) =="
SENT_SEQ="$("$BIN" message --target "$TMP" --home "$HOME_TMP" --to team --text "ack-of forwarding test" --as forge-lead | sed -n 's/.*seq=//p')"
bash "$HERE/scripts/mesh.sh" activity reading --ack-of "$SENT_SEQ" --as forge-lead >/dev/null 2>&1 || true
ACK_CHECK="$(curl -fsS "http://127.0.0.1:$PORT/api/events?since=0" -H "Authorization: Bearer $TOKEN" | python3 -c "
import json, sys
data = json.load(sys.stdin)
print(any(e.get('type') == 'message.read' and e.get('ack_of') == $SENT_SEQ for e in data['events']))
")"
chk "activity --ack-of reaches the binary and creates a message.read receipt" "[ \"\$ACK_CHECK\" = 'True' ]"
```

Adapt variable names (`$BIN`/`$TMP`/`$HOME_TMP`/`$PORT`/`$TOKEN`/`--as` actor) to whatever this test file's established conventions actually are at the point you insert this — re-read the file first. Note: this specific ack scenario needs the acking actor (`forge-lead` in the sketch above) to be a plausible addressee of the referenced message per `validate_ack`'s rules (room-broadcast messages with no explicit `to` can be acked by any room member) — if the real test fixture's messaging setup differs, adjust the message's `--to`/room so the ack is valid, not rejected by `validate_ack` for an unrelated reason.

- [ ] **Step 2: Run test to verify it fails**

Run: `bash test/mesh-command-center.test.sh 2>&1 | grep -A2 "ack-of forwarding"`
Expected: FAIL — no `message.read` event is created today; `--ack-of` is silently dropped.

- [ ] **Step 3: Forward all arguments**

```bash
  activity)
    require_arg "activity state" "${1:-}"
    exec "$BIN" activity "${PROJECT_ARGS[@]}" "$@" "${AS_ARGS[@]}"
    ;;
```

(Changed `"$1"` to `"$@"` — this now matches `availability`'s pattern exactly, letting clap parse/validate/reject any additional flags including `--ack-of`.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash test/mesh-command-center.test.sh 2>&1 | tail -60`
Run: `bash test/all.sh 2>&1 | tail -80`
Expected: PASS — including the new ack-of check, and every existing bare `mesh.sh activity reading|typing|idle` call (no extra args) unaffected since `"$@"` with only the state word present behaves identically to `"$1"` did.

- [ ] **Step 5: Commit**

```bash
git add scripts/mesh.sh test/mesh-command-center.test.sh
git commit -m "fix(mesh): activity forwards all arguments so --ack-of reaches the binary"
```

---

### Task 7: Command center must be usable on a phone-width viewport

**Files:**
- Modify: `crates/workbench-mesh/assets/command-center/style.css` (topbar/nav)
- Modify: `crates/workbench-mesh/assets/command-center/style-surfaces.css` (per-surface layout grids)

**Interfaces:** none — pure CSS addition, no JS/markup changes.

**The bug:** zero width-based `@media` rules exist anywhere in the command center (the only rule is `prefers-reduced-motion`). At 390px: the topbar's Ops/Docs tabs are pushed off-screen with no scroll and no hamburger; every surface's fixed-width sidebar (`.foryou` 304px on Bench, `.host-grid`'s 328px column + `.two-col`/`.three-col` on Host, `.event-rail` 324px on Ops, `.docs-nav` 224px on Docs) squeezes real content into single letters per line; Board's `.decisions`-style right rail (same rail pattern as the others) dominates while the kanban lanes shrink to a sliver.

- [ ] **Step 1: Manual verification baseline**

If you can drive a browser (chrome-devtools/playwright tools), start a real mesh server, open the dashboard, resize to 390×844, and screenshot each of the 5 tabs (Bench/Board/Host/Ops/Docs) to have a concrete "before" reference. If you cannot drive a browser, read the current CSS carefully instead and rely on the exact selectors named below (already confirmed correct against the current file by the audit and by direct grep before this plan was written).

- [ ] **Step 2: Add the nav fix to `style.css`**

Append to the end of `style.css` (a fresh block, not nested inside the existing `@media (prefers-reduced-motion: reduce)` rule):

```css
@media (max-width: 768px) {
  .topbar {
    overflow-x: auto;
    -webkit-overflow-scrolling: touch;
  }
  .tabs, .topbar-right {
    flex-shrink: 0;
  }
}
```

- [ ] **Step 3: Add the per-surface stacking fixes to `style-surfaces.css`**

Append to the end of `style-surfaces.css`:

```css
@media (max-width: 768px) {
  /* Bench: stack the For-You rail below chat instead of beside it. */
  .bench-below {
    flex-direction: column;
  }
  .chat-col {
    margin: 14px;
  }
  .foryou {
    width: auto;
    border-left: none;
    border-top: 1px solid var(--line);
  }

  /* Board: the Decisions rail uses the same .foryou/.drail sidebar pattern
     as Bench — confirm the exact class Board's rail actually uses (read
     board.js's render function) and add it alongside .foryou above if it
     differs; if Board reuses .foryou directly, this rule already covers it. */

  /* Host: collapse the two/three-column grids to one column. */
  .host-grid,
  .two-col,
  .three-col {
    grid-template-columns: 1fr;
  }

  /* Ops: stack the event rail below the main content instead of beside it. */
  .ops-wrap {
    flex-direction: column;
  }
  .event-rail {
    width: auto;
    border-left: none;
    border-top: 1px solid var(--line);
  }

  /* Docs: stack the nav above content instead of beside it, and stop it
     being sticky/full-height once it's no longer a side column. */
  .docs-wrap {
    flex-direction: column;
  }
  .docs-nav {
    width: auto;
    border-right: none;
    border-bottom: 1px solid var(--line);
    position: static;
    height: auto;
  }
  .whatis-cols,
  .proj-callouts,
  .rungs,
  .preview-cols {
    grid-template-columns: 1fr;
  }
}
```

Before finalizing, grep `board.js` for the class its Decisions rail actually renders (`grep -n "class.*drail\|class.*foryou\|WB.renderForYou" crates/workbench-mesh/assets/command-center/board.js`) — the plan's research found Board's rail rendered via the same `WB.renderForYou` helper Bench uses, which would mean it already carries the `.foryou` class and needs no separate rule; confirm this directly rather than assuming, and add a Board-specific rule only if the class actually differs.

- [ ] **Step 4: Verify**

If you can drive a browser: reload each of the 5 tabs at 390×844, confirm the nav is scrollable (or at minimum every tab button is reachable), confirm each surface's sidebar now stacks below its main content instead of squeezing it, and confirm `document.documentElement.scrollWidth` is now ≤ the viewport width (390) on every tab — the audit's own repro check. Also verify at a normal desktop width (e.g. 1440×900) that nothing regressed — the `max-width: 768px` gate should mean desktop layouts are completely untouched.

If you cannot drive a browser, state that plainly in your report, and instead verify by reading the CSS cascade carefully: confirm the new rules only apply under `max-width: 768px` (never overriding desktop), and confirm every selector referenced actually exists in the current files (re-grep after your edit to be sure you didn't introduce a typo'd class name that silently does nothing).

Run: `bash test/mesh-command-center.test.sh 2>&1 | tail -40` (CSS-only change, should be unaffected, but confirms nothing else broke).

- [ ] **Step 5: Commit**

```bash
git add crates/workbench-mesh/assets/command-center/style.css crates/workbench-mesh/assets/command-center/style-surfaces.css
git commit -m "fix(mesh): add a mobile breakpoint — stack sidebars, collapse grids, scrollable nav"
```
