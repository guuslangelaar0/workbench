# Mesh Real-Time Protocol & Chat UX Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the mesh dashboard from a poll-heavy broadcast-everything console into a WS-native chat with real delivery/seen receipts, per-room subscription filtering, paginated/virtualized rendering, and a persistent per-actor connector that ACKs at wire speed.

**Architecture:** Rust/axum server replaces its single global broadcast channel with per-room + per-actor channels behind a subscribe control frame, and micro-batches live pushes. A new `workbench-mesh listen` connector (persistent WS client, uses `tokio-tungstenite`) ACKs inbound messages instantly and feeds a per-actor FIFO that replaces the polling wake loop. The vanilla-JS dashboard (`live.js`/`bench.js`) adds pagination, optimistic send, receipt ticks, RTT display, and animated chunk reveal — no framework, no build step.

**Tech Stack:** Rust (axum, tokio, tokio-tungstenite), vanilla JS/CSS (no bundler), bash (`scripts/mesh.sh`).

## Global Constraints

- No wire-format change beyond the fields specified in this plan — JSON stays JSON (spec: "Binary wire format... not worth the complexity yet").
- `ack_of` is a top-level `EventEnvelope` field, not nested in `payload` (spec: "Protocol & event schema").
- ACK scope is addressee-only: a DM is acked only by its recipient; a room post is acked once per subscribed member (spec: "ACK scope").
- Micro-batch flush window is ~16ms (spec: "Server-side subscription filtering").
- Chat page size is a fixed 50 messages, DOM mount cap ~150 rows per open thread (spec: "Chat pagination & rendering").
- Reconnect: 250ms first retry, capped jittered exponential backoff to ~5s (spec: "Presence freshness & reconnect").
- RTT ping cadence is ~5s, app-level for the browser client (native WS ping/pong isn't observable from browser JS), native WS ping/pong for the Rust connector (spec: "RTT / connection insight").
- No true token-level streaming (`output.delta`) and no intent-based forwarding in this plan — both are explicitly out of scope (spec: "Scope — Out of scope").
- Every new Rust module follows the existing crate's error-handling convention: `anyhow::Result`, `.context(...)` on fallible I/O, no `unwrap()` outside tests.
- Every CLI flag follows the existing `--as`/env-var/default fallback pattern (`resolve_actor`, `resolve_identity_field` in `client.rs`) — never invent a new resolution order.

---

## File Structure

**Rust (`crates/workbench-mesh/`):**
- `Cargo.toml` — move `tokio-tungstenite` from `[dev-dependencies]` to `[dependencies]` (Task 7).
- `src/protocol.rs` — add `ack_of` field + validation (Task 1).
- `src/store.rs` — add `list_events_page` for cursor pagination (Task 4).
- `src/server.rs` — subscription registry, micro-batching, pagination endpoint, app-level ping/pong (Tasks 2, 3, 4, 5).
- `src/client.rs` — `ack_of` plumbing through `append_or_post_event`, `--ack-of` on `set_activity` (Task 6).
- `src/listen.rs` — **new file**: the persistent connector (Tasks 7, 8).
- `src/main.rs` — `Listen(ListenArgs)` subcommand wiring (Task 7).

**Frontend (`crates/workbench-mesh/assets/command-center/`):**
- `live.js` — subscribe frame, batch-frame handling, reconnect backoff, pagination, optimistic send, receipts, app-level ping/pong (Tasks 9–12).
- `bench.js` — mount cap + `content-visibility`, load-older, receipt ticks, RTT badge, animated reveal (Tasks 13–15).
- `style-surfaces.css` — new classes for receipt ticks, RTT badge, reveal cursor (Tasks 14, 15).

**Ops:**
- `scripts/mesh.sh` — `listen-wait` operation replacing the polling loop inside `inbox --wait` for actors with a running `listen` connector (Task 16).
- `skills/mesh/SKILL.md` — routing update (Task 16).

---

### Task 1: Protocol — `ack_of` field and validation

**Files:**
- Modify: `crates/workbench-mesh/src/protocol.rs`
- Test: `crates/workbench-mesh/src/protocol.rs` (inline `#[cfg(test)]`)

**Interfaces:**
- Produces: `EventEnvelope.ack_of: Option<u64>`; `pub fn validate_ack(ack_of: Option<u64>, event_type: &str, from: &str, to: Option<&str>, room: &str, referenced: Option<&EventEnvelope>) -> anyhow::Result<()>`.

- [ ] **Step 1: Write the failing tests**

Add to the `tests` module in `protocol.rs`:

```rust
    #[test]
    fn ack_requires_delivered_or_read_type() {
        let referenced = sample_event("message.sent", "repo:workbench", "session:lead", Some("session:worker"));
        let err = validate_ack(Some(1), "message.sent", "session:worker", Some("session:lead"), "repo:workbench", Some(&referenced)).unwrap_err();
        assert!(err.to_string().contains("ack_of is only valid on message.delivered/message.read"));
    }

    #[test]
    fn ack_requires_a_referenced_event() {
        let err = validate_ack(Some(1), "message.delivered", "session:worker", None, "repo:workbench", None).unwrap_err();
        assert!(err.to_string().contains("ack_of references an unknown seq"));
    }

    #[test]
    fn ack_rejects_actor_who_was_not_addressed() {
        let referenced = sample_event("message.sent", "repo:workbench", "session:lead", Some("session:worker"));
        let err = validate_ack(Some(1), "message.delivered", "session:bystander", None, "repo:workbench", Some(&referenced)).unwrap_err();
        assert!(err.to_string().contains("ack_of actor was not addressed by the referenced event"));
    }

    #[test]
    fn ack_allows_direct_addressee() {
        let referenced = sample_event("message.sent", "repo:workbench", "session:lead", Some("session:worker"));
        validate_ack(Some(1), "message.delivered", "session:worker", None, "repo:workbench", Some(&referenced)).unwrap();
    }

    #[test]
    fn ack_allows_room_member_when_no_explicit_to() {
        let referenced = sample_event("message.sent", "repo:workbench", "session:lead", None);
        validate_ack(Some(1), "message.read", "session:worker", None, "repo:workbench", Some(&referenced)).unwrap();
    }

    #[test]
    fn ack_rejects_mismatched_room() {
        let referenced = sample_event("message.sent", "repo:workbench", "session:lead", None);
        let err = validate_ack(Some(1), "message.delivered", "session:worker", None, "repo:other", Some(&referenced)).unwrap_err();
        assert!(err.to_string().contains("ack_of room mismatch"));
    }

    #[test]
    fn non_ack_events_require_ack_of_to_be_absent() {
        let err = validate_ack(Some(1), "message.sent", "session:lead", None, "repo:workbench", None).unwrap_err();
        assert!(err.to_string().contains("ack_of is only valid on message.delivered/message.read"));
    }

    fn sample_event(event_type: &str, room: &str, from: &str, to: Option<&str>) -> EventEnvelope {
        EventEnvelope {
            v: 1,
            id: "test-id".to_string(),
            seq: 1,
            event_type: event_type.to_string(),
            room: room.to_string(),
            from: from.to_string(),
            to: to.map(str::to_string),
            ts: "2026-07-03T00:00:00Z".to_string(),
            payload: serde_json::json!({}),
        }
    }
```

Also update the `use` line at the top of the test module:

```rust
    use super::{validate_ack, validate_event_room, validate_event_type, ALLOWED_EVENT_TYPES};
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cargo test -p workbench-mesh protocol:: 2>&1 | tail -30`
Expected: FAIL — `validate_ack` not found / does not compile.

- [ ] **Step 3: Add the `ack_of` field and `validate_ack`**

Modify the `EventEnvelope` struct:

```rust
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct EventEnvelope {
    pub v: u16,
    pub id: String,
    pub seq: u64,
    #[serde(rename = "type")]
    pub event_type: String,
    pub room: String,
    pub from: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub to: Option<String>,
    pub ts: String,
    pub payload: Value,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub ack_of: Option<u64>,
}
```

Add after `validate_event_room`:

```rust
/// `ack_of` links a `message.delivered`/`message.read` receipt back to the
/// event it acknowledges. Only those two types may carry it; the acking
/// actor must have actually been addressed by the referenced event (its
/// direct `to`, or any subscriber of the referenced event's room when there
/// was no explicit `to`), and the ack must stay in the same room as the
/// event it references — an ack is not a way to smuggle a message into a
/// different room.
pub fn validate_ack(
    ack_of: Option<u64>,
    event_type: &str,
    from: &str,
    to: Option<&str>,
    room: &str,
    referenced: Option<&EventEnvelope>,
) -> anyhow::Result<()> {
    let is_ack_type = event_type == "message.delivered" || event_type == "message.read";
    let Some(ack_seq) = ack_of else {
        if is_ack_type {
            anyhow::bail!("{event_type} requires ack_of");
        }
        return Ok(());
    };
    if !is_ack_type {
        anyhow::bail!("ack_of is only valid on message.delivered/message.read, got: {event_type}");
    }
    let _ = to; // reserved: the acking event's own `to` is not consulted, only the referenced event's addressing
    let Some(referenced) = referenced else {
        anyhow::bail!("ack_of references an unknown seq: {ack_seq}");
    };
    if referenced.room != room {
        anyhow::bail!(
            "ack_of room mismatch: referenced event is in {}, ack posted to {room}",
            referenced.room
        );
    }
    let addressed = match &referenced.to {
        Some(direct) => direct == from,
        None => true, // no explicit addressee — any room member may ack
    };
    if !addressed {
        anyhow::bail!("ack_of actor was not addressed by the referenced event");
    }
    Ok(())
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cargo test -p workbench-mesh protocol:: 2>&1 | tail -30`
Expected: PASS — all `protocol::tests::*` green, including the new `ack_*` tests and the existing `validates_known_event_types`/`output_chunk_*` tests unaffected.

- [ ] **Step 5: Commit**

```bash
git add crates/workbench-mesh/src/protocol.rs
git commit -m "feat(mesh): add ack_of envelope field and validation"
```

---

### Task 2: Store — event lookup by seq (needed for ack validation)

**Files:**
- Modify: `crates/workbench-mesh/src/store.rs`
- Test: `crates/workbench-mesh/src/store.rs` (inline)

**Interfaces:**
- Consumes: `EventEnvelope` (Task 1).
- Produces: `pub fn get_event(&self, seq: u64) -> anyhow::Result<Option<EventEnvelope>>`.

- [ ] **Step 1: Write the failing test**

Add to `store.rs`'s existing `#[cfg(test)]` module (find it via `grep -n "mod tests" crates/workbench-mesh/src/store.rs` — append alongside the existing tests):

```rust
    #[test]
    fn get_event_returns_the_matching_envelope_or_none() {
        let project = TempDir::new().unwrap();
        let store = MeshStore::open(project.path()).unwrap();
        let appended = store
            .append_event("message.sent", "repo:workbench", "session:lead", None, json!({ "text": "hi" }))
            .unwrap();

        let found = store.get_event(appended.seq).unwrap();
        assert_eq!(found.unwrap().id, appended.id);

        let missing = store.get_event(appended.seq + 100).unwrap();
        assert!(missing.is_none());
    }
```

If the test module doesn't already import `TempDir`/`json`, add:

```rust
    use tempfile::TempDir;
    use serde_json::json;
```

(Check first — `store.rs`'s existing tests very likely already import these; don't duplicate.)

- [ ] **Step 2: Run test to verify it fails**

Run: `cargo test -p workbench-mesh store::tests::get_event_returns_the_matching_envelope_or_none 2>&1 | tail -20`
Expected: FAIL — `get_event` not found.

- [ ] **Step 3: Implement `get_event`**

Add to `impl MeshStore` in `store.rs`, right after `list_events_since`:

```rust
    /// Look up a single event by seq — used to validate that a
    /// `message.delivered`/`message.read` ack actually references a real
    /// event this actor was addressed by.
    pub fn get_event(&self, seq: u64) -> Result<Option<EventEnvelope>> {
        Ok(self
            .list_events_since(seq.saturating_sub(1))?
            .into_iter()
            .find(|event| event.seq == seq))
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cargo test -p workbench-mesh store:: 2>&1 | tail -30`
Expected: PASS — all `store::tests::*` green.

- [ ] **Step 5: Commit**

```bash
git add crates/workbench-mesh/src/store.rs
git commit -m "feat(mesh): add MeshStore::get_event for ack validation lookups"
```

---

### Task 3: Store — cursor pagination (`list_events_page`)

**Files:**
- Modify: `crates/workbench-mesh/src/store.rs`
- Test: `crates/workbench-mesh/src/store.rs` (inline)

**Interfaces:**
- Produces: `pub fn list_events_page(&self, room: Option<&str>, before: Option<u64>, limit: usize) -> anyhow::Result<Vec<EventEnvelope>>` — returns up to `limit` events with `seq < before` (or all if `before` is `None`), optionally filtered to `room`, **newest-first**.

- [ ] **Step 1: Write the failing test**

Add to `store.rs`'s test module:

```rust
    #[test]
    fn list_events_page_windows_by_room_and_before_newest_first() {
        let project = TempDir::new().unwrap();
        let store = MeshStore::open(project.path()).unwrap();
        for i in 0..5 {
            store
                .append_event("message.sent", "repo:workbench", "session:lead", None, json!({ "text": format!("a{i}") }))
                .unwrap();
            store
                .append_event("message.sent", "repo:other", "session:lead", None, json!({ "text": format!("b{i}") }))
                .unwrap();
        }
        // 10 events total, seqs 1..=10, alternating repo:workbench / repo:other

        let page = store.list_events_page(Some("repo:workbench"), None, 2).unwrap();
        assert_eq!(page.len(), 2);
        assert_eq!(page[0].payload["text"], "a4"); // newest first
        assert_eq!(page[1].payload["text"], "a3");

        let older = store
            .list_events_page(Some("repo:workbench"), Some(page[1].seq), 2)
            .unwrap();
        assert_eq!(older.len(), 2);
        assert_eq!(older[0].payload["text"], "a2");
        assert_eq!(older[1].payload["text"], "a1");

        let unfiltered = store.list_events_page(None, None, 3).unwrap();
        assert_eq!(unfiltered.len(), 3);
        assert_eq!(unfiltered[0].payload["text"], "b4");
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cargo test -p workbench-mesh store::tests::list_events_page_windows_by_room_and_before_newest_first 2>&1 | tail -20`
Expected: FAIL — `list_events_page` not found.

- [ ] **Step 3: Implement `list_events_page`**

Add to `impl MeshStore`, after `get_event`:

```rust
    /// Cursor pagination for the chat pane: the last `limit` events in
    /// `room` (or across all rooms if `room` is None) with seq strictly less
    /// than `before` (or unbounded if `before` is None), newest-first. Reads
    /// the whole log like `list_events_since` — event logs at this scale
    /// (a dev mesh, not a production message queue) are small enough that a
    /// dedicated index isn't justified yet.
    pub fn list_events_page(
        &self,
        room: Option<&str>,
        before: Option<u64>,
        limit: usize,
    ) -> Result<Vec<EventEnvelope>> {
        let ceiling = before.unwrap_or(u64::MAX);
        let mut matching: Vec<EventEnvelope> = self
            .list_events_since(0)?
            .into_iter()
            .filter(|event| event.seq < ceiling)
            .filter(|event| room.is_none_or(|r| event.room == r))
            .collect();
        matching.sort_by(|left, right| right.seq.cmp(&left.seq));
        matching.truncate(limit);
        Ok(matching)
    }
```

If the crate's Rust edition predates `Option::is_none_or` (stabilized 1.82), use instead:
`.filter(|event| room.map(|r| event.room == r).unwrap_or(true))`. Check `rustc --version`; the workspace `Cargo.toml`'s `edition.workspace = true` — if `cargo build` errors on `is_none_or`, switch to the `.map(...).unwrap_or(true)` form.

- [ ] **Step 4: Run test to verify it passes**

Run: `cargo test -p workbench-mesh store:: 2>&1 | tail -30`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add crates/workbench-mesh/src/store.rs
git commit -m "feat(mesh): add MeshStore::list_events_page for chat pagination"
```

---

### Task 4: Server — accept and validate `ack_of` on posted events

**Files:**
- Modify: `crates/workbench-mesh/src/server.rs`
- Test: `crates/workbench-mesh/src/server.rs` (inline `#[cfg(test)]`)

**Interfaces:**
- Consumes: `MeshStore::get_event` (Task 2), `protocol::validate_ack` (Task 1).
- Produces: `EventRequest.ack_of: Option<u64>`; `append_event` now validates and stores it.

- [ ] **Step 1: Write the failing test**

Add to `server.rs`'s `#[cfg(test)]` module, near `daemon_local_token_is_rejected_after_starting_device_is_revoked`:

```rust
    #[tokio::test]
    async fn ack_of_round_trips_and_rejects_unaddressed_actor() {
        let project = TempDir::new().unwrap();
        let home = TempDir::new().unwrap();
        write_project_config(project.path(), "Mesh Service");
        auth::bootstrap(project.path(), Some(home.path().to_path_buf())).unwrap();
        let owner_token =
            auth::local_project_token(project.path(), Some(home.path().to_path_buf())).unwrap();

        let server = tokio::spawn(serve(ServeOptions {
            project_root: project.path().to_path_buf(),
            home: Some(home.path().to_path_buf()),
            bind: "local".to_string(),
            port: 0,
            pid_file: None,
            started_by: None,
        }));
        let metadata = wait_for_metadata(project.path()).await;
        let base = format!("http://{}:{}", metadata.host, metadata.port);
        let client = Client::new();

        let sent: Value = client
            .post(format!("{base}/api/events"))
            .bearer_auth(&owner_token)
            .json(&json!({
                "type": "message.sent",
                "room": "repo:mesh-service",
                "from": "session:lead",
                "to": "session:worker",
                "payload": { "text": "status?" }
            }))
            .send()
            .await
            .unwrap()
            .error_for_status()
            .unwrap()
            .json()
            .await
            .unwrap();
        let sent_seq = sent["seq"].as_u64().unwrap();

        let ack = client
            .post(format!("{base}/api/events"))
            .bearer_auth(&owner_token)
            .json(&json!({
                "type": "message.delivered",
                "room": "repo:mesh-service",
                "from": "session:worker",
                "ack_of": sent_seq,
                "payload": {}
            }))
            .send()
            .await
            .unwrap();
        assert_eq!(ack.status(), reqwest::StatusCode::OK);
        let ack_body: Value = ack.json().await.unwrap();
        assert_eq!(ack_body["ack_of"], sent_seq);

        let rejected = client
            .post(format!("{base}/api/events"))
            .bearer_auth(&owner_token)
            .json(&json!({
                "type": "message.delivered",
                "room": "repo:mesh-service",
                "from": "session:bystander",
                "ack_of": sent_seq,
                "payload": {}
            }))
            .send()
            .await
            .unwrap();
        assert_eq!(rejected.status(), reqwest::StatusCode::BAD_REQUEST);

        server.abort();
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cargo test -p workbench-mesh server::tests::ack_of_round_trips_and_rejects_unaddressed_actor 2>&1 | tail -30`
Expected: FAIL — `ack_of` field doesn't exist on `EventRequest` yet / not returned in response.

- [ ] **Step 3: Wire `ack_of` through `EventRequest` and `append_event`**

Modify `EventRequest`:

```rust
#[derive(Debug, Deserialize)]
struct EventRequest {
    #[serde(rename = "type")]
    event_type: String,
    room: String,
    from: String,
    to: Option<String>,
    payload: Value,
    #[serde(default)]
    ack_of: Option<u64>,
}
```

Modify `append_event`:

```rust
fn append_event(state: &AppState, request: EventRequest) -> Result<EventEnvelope> {
    let referenced = match request.ack_of {
        Some(seq) => state.store.get_event(seq)?,
        None => None,
    };
    crate::protocol::validate_ack(
        request.ack_of,
        &request.event_type,
        &request.from,
        request.to.as_deref(),
        &request.room,
        referenced.as_ref(),
    )?;
    let mut daemon_broadcast_seqs = state.daemon_broadcast_seqs.lock().ok();
    let mut event = state.store.append_event(
        &request.event_type,
        &request.room,
        &request.from,
        request.to.as_deref(),
        request.payload,
    )?;
    event.ack_of = request.ack_of;
    let should_broadcast = daemon_broadcast_seqs
        .as_mut()
        .map(|seqs| remember_daemon_broadcast_seq(seqs, &state.tail_scan_seq, event.seq))
        .unwrap_or(true);
    if should_broadcast {
        let _ = state.events_tx.send(event.clone());
    }
    Ok(event)
}
```

This stamps `ack_of` onto the in-memory response/broadcast envelope, but note `MeshStore::append_event` (Task 1/2's `store.rs`) doesn't persist `ack_of` yet — the field is `#[serde(skip_serializing_if = "Option::is_none")]` on the struct, but `store::append_locked_jsonl`'s `build_event` closure in `append_event` constructs the envelope without it, so it's always `None` when read back from disk. Fix `MeshStore::append_event` to accept and persist it:

```rust
    pub fn append_event(
        &self,
        event_type: &str,
        room: &str,
        from: &str,
        to: Option<&str>,
        payload: Value,
    ) -> Result<EventEnvelope> {
        self.append_event_with_ack(event_type, room, from, to, payload, None)
    }

    pub fn append_event_with_ack(
        &self,
        event_type: &str,
        room: &str,
        from: &str,
        to: Option<&str>,
        payload: Value,
        ack_of: Option<u64>,
    ) -> Result<EventEnvelope> {
        validate_event_type(event_type)?;
        validate_event_room(event_type, room)?;
        let path = self.root.join("events.jsonl");
        append_locked_jsonl(&path, |seq| {
            Ok(EventEnvelope {
                v: 1,
                id: Uuid::now_v7().to_string(),
                seq,
                event_type: event_type.to_string(),
                room: room.to_string(),
                from: from.to_string(),
                to: to.map(str::to_string),
                ts: OffsetDateTime::now_utc()
                    .format(&Rfc3339)
                    .context("format event timestamp")?,
                payload,
                ack_of,
            })
        })
    }
```

(Every other `EventEnvelope` construction site in `store.rs`, e.g. `append_audit`, must also add `ack_of: None` to its struct literal — the compiler will point at each one; fix them all.)

Now update `server.rs`'s `append_event` free function to call the new store method directly instead of mutating `event.ack_of` after the fact:

```rust
fn append_event(state: &AppState, request: EventRequest) -> Result<EventEnvelope> {
    let referenced = match request.ack_of {
        Some(seq) => state.store.get_event(seq)?,
        None => None,
    };
    crate::protocol::validate_ack(
        request.ack_of,
        &request.event_type,
        &request.from,
        request.to.as_deref(),
        &request.room,
        referenced.as_ref(),
    )?;
    let mut daemon_broadcast_seqs = state.daemon_broadcast_seqs.lock().ok();
    let event = state.store.append_event_with_ack(
        &request.event_type,
        &request.room,
        &request.from,
        request.to.as_deref(),
        request.payload,
        request.ack_of,
    )?;
    let should_broadcast = daemon_broadcast_seqs
        .as_mut()
        .map(|seqs| remember_daemon_broadcast_seq(seqs, &state.tail_scan_seq, event.seq))
        .unwrap_or(true);
    if should_broadcast {
        let _ = state.events_tx.send(event.clone());
    }
    Ok(event)
}
```

- [ ] **Step 4: Fix every other `EventEnvelope` struct-literal build site**

Run: `cargo build -p workbench-mesh 2>&1 | grep -A2 "missing field \`ack_of\`"`

Every hit is a struct literal (`store.rs::append_audit`'s closure, and any test helper building an `EventEnvelope` literal directly rather than through `append_event`) — add `ack_of: None,` to each.

- [ ] **Step 5: Run tests to verify they pass**

Run: `cargo test -p workbench-mesh 2>&1 | tail -40`
Expected: PASS — full crate test suite green, including the new `ack_of_round_trips_and_rejects_unaddressed_actor`.

- [ ] **Step 6: Commit**

```bash
git add crates/workbench-mesh/src/server.rs crates/workbench-mesh/src/store.rs
git commit -m "feat(mesh): validate and persist ack_of on posted events"
```

---

### Task 5: Server — per-room/per-actor subscription channels + subscribe frame

**Files:**
- Modify: `crates/workbench-mesh/src/server.rs`
- Test: `crates/workbench-mesh/src/server.rs` (inline)

**Interfaces:**
- Consumes: existing `AppState`, `websocket_session`.
- Produces: `AppState.channels: Arc<Mutex<ChannelRegistry>>`; each WS session tracks its own subscription set and only forwards matching events.

This is the highest-risk task — it replaces `AppState.events_tx: broadcast::Sender<EventEnvelope>` (a single global channel every socket subscribes to) with a registry of per-room broadcast channels plus a per-actor unicast channel, and adds a `{"type":"subscribe","rooms":[...]}` control frame so each socket only receives what it asked for (plus its own actor's direct messages, always).

- [ ] **Step 1: Write the failing test**

Add to `server.rs`'s test module:

```rust
    #[tokio::test]
    async fn subscription_filters_room_traffic_but_always_delivers_direct_messages() {
        let project = TempDir::new().unwrap();
        let home = TempDir::new().unwrap();
        write_project_config(project.path(), "Mesh Service");
        auth::bootstrap(project.path(), Some(home.path().to_path_buf())).unwrap();
        let owner_token =
            auth::local_project_token(project.path(), Some(home.path().to_path_buf())).unwrap();

        let server = tokio::spawn(serve(ServeOptions {
            project_root: project.path().to_path_buf(),
            home: Some(home.path().to_path_buf()),
            bind: "local".to_string(),
            port: 0,
            pid_file: None,
            started_by: None,
        }));
        let metadata = wait_for_metadata(project.path()).await;

        // socket A subscribes only to repo:a; socket B subscribes only to repo:b
        let (mut a, _) = connect_async(format!(
            "ws://{}:{}/ws?token={}&last_seq=0",
            metadata.host, metadata.port, metadata.local_token
        ))
        .await
        .unwrap();
        a.send(ClientMessage::Text(
            json!({ "v": 1, "type": "subscribe", "rooms": ["repo:a"] }).to_string(),
        ))
        .await
        .unwrap();

        let (mut b, _) = connect_async(format!(
            "ws://{}:{}/ws?token={}&last_seq=0",
            metadata.host, metadata.port, metadata.local_token
        ))
        .await
        .unwrap();
        b.send(ClientMessage::Text(
            json!({ "v": 1, "type": "subscribe", "rooms": ["repo:b"] }).to_string(),
        ))
        .await
        .unwrap();

        // give the server a beat to register both subscriptions before posting
        sleep(Duration::from_millis(50)).await;

        let client = Client::new();
        let base = format!("http://{}:{}", metadata.host, metadata.port);
        client
            .post(format!("{base}/api/events"))
            .bearer_auth(&owner_token)
            .json(&json!({ "type": "message.sent", "room": "repo:b", "from": "session:lead", "payload": { "text": "for b only" } }))
            .send()
            .await
            .unwrap()
            .error_for_status()
            .unwrap();

        // B receives it
        let received = read_ws_json(&mut b).await;
        assert_eq!(received["room"], "repo:b");

        // A does not — post a repo:a event afterward and confirm A gets THAT
        // one next (i.e. it never silently received the repo:b traffic first)
        client
            .post(format!("{base}/api/events"))
            .bearer_auth(&owner_token)
            .json(&json!({ "type": "message.sent", "room": "repo:a", "from": "session:lead", "payload": { "text": "for a only" } }))
            .send()
            .await
            .unwrap()
            .error_for_status()
            .unwrap();
        let received_a = read_ws_json(&mut a).await;
        assert_eq!(received_a["room"], "repo:a");

        server.abort();
    }

    #[tokio::test]
    async fn direct_messages_always_deliver_regardless_of_room_subscription() {
        let project = TempDir::new().unwrap();
        let home = TempDir::new().unwrap();
        write_project_config(project.path(), "Mesh Service");
        auth::bootstrap(project.path(), Some(home.path().to_path_buf())).unwrap();
        let owner_token =
            auth::local_project_token(project.path(), Some(home.path().to_path_buf())).unwrap();

        let server = tokio::spawn(serve(ServeOptions {
            project_root: project.path().to_path_buf(),
            home: Some(home.path().to_path_buf()),
            bind: "local".to_string(),
            port: 0,
            pid_file: None,
            started_by: None,
        }));
        let metadata = wait_for_metadata(project.path()).await;

        // socket subscribes to a room it will never receive DM traffic in,
        // but identifies itself as session:worker via the subscribe frame
        let (mut worker, _) = connect_async(format!(
            "ws://{}:{}/ws?token={}&last_seq=0",
            metadata.host, metadata.port, metadata.local_token
        ))
        .await
        .unwrap();
        worker
            .send(ClientMessage::Text(
                json!({ "v": 1, "type": "subscribe", "rooms": [], "actor": "session:worker" }).to_string(),
            ))
            .await
            .unwrap();
        sleep(Duration::from_millis(50)).await;

        let client = Client::new();
        let base = format!("http://{}:{}", metadata.host, metadata.port);
        client
            .post(format!("{base}/api/events"))
            .bearer_auth(&owner_token)
            .json(&json!({ "type": "message.sent", "room": "direct:session:worker", "from": "session:lead", "to": "session:worker", "payload": { "text": "dm" } }))
            .send()
            .await
            .unwrap()
            .error_for_status()
            .unwrap();

        let received = read_ws_json(&mut worker).await;
        assert_eq!(received["to"], "session:worker");

        server.abort();
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cargo test -p workbench-mesh server::tests::subscription_filters server::tests::direct_messages_always 2>&1 | tail -40`
Expected: FAIL — currently every socket receives every broadcast event unconditionally, so `direct_messages_always...` may pass by accident but `subscription_filters_room_traffic...` fails (socket A receives the `repo:b` event first).

- [ ] **Step 3: Implement the subscription registry**

Add a channel registry type near the top of `server.rs`, replacing the single `events_tx` field:

```rust
#[derive(Default)]
struct ChannelRegistry {
    rooms: std::collections::HashMap<String, broadcast::Sender<EventEnvelope>>,
    actors: std::collections::HashMap<String, broadcast::Sender<EventEnvelope>>,
}

impl ChannelRegistry {
    fn room_sender(&mut self, room: &str) -> broadcast::Sender<EventEnvelope> {
        self.rooms
            .entry(room.to_string())
            .or_insert_with(|| broadcast::channel(256).0)
            .clone()
    }

    fn actor_sender(&mut self, actor: &str) -> broadcast::Sender<EventEnvelope> {
        self.actors
            .entry(actor.to_string())
            .or_insert_with(|| broadcast::channel(256).0)
            .clone()
    }

    /// Fan out one event to its room channel, and — if it has a direct `to`
    /// distinct from its room (a DM, not a room broadcast) — to that actor's
    /// unicast channel too.
    fn dispatch(&mut self, event: &EventEnvelope) {
        let _ = self.room_sender(&event.room).send(event.clone());
        if let Some(to) = &event.to {
            if to != &event.room {
                let _ = self.actor_sender(to).send(event.clone());
            }
        }
    }
}
```

Modify `AppState`:

```rust
#[derive(Clone)]
struct AppState {
    project_root: PathBuf,
    home: Option<PathBuf>,
    store: Arc<MeshStore>,
    channels: Arc<Mutex<ChannelRegistry>>,
    daemon_token: String,
    local_credential_token: String,
    tail_scan_seq: Arc<AtomicU64>,
    daemon_broadcast_seqs: Arc<Mutex<BTreeSet<u64>>>,
    connect_urls: Vec<ConnectUrl>,
    host_meta: Value,
}
```

Every other reference to `state.events_tx.send(...)` becomes `state.channels.lock().unwrap().dispatch(&event)`. In `serve()`:

```rust
    let (events_tx, _) = broadcast::channel(256);
```

becomes:

```rust
    let channels = Arc::new(Mutex::new(ChannelRegistry::default()));
```

and the `AppState { ... }` literal's `events_tx: events_tx,` line becomes `channels: channels.clone(),` — then `tail_store_events`'s calls to `state.events_tx.send(event)` become `state.channels.lock().unwrap().dispatch(&event)`. Search every occurrence:

Run: `grep -n "events_tx" crates/workbench-mesh/src/server.rs`

Every hit must be updated: `append_event`'s `let _ = state.events_tx.send(event.clone());` → `state.channels.lock().unwrap().dispatch(&event);`, `tail_store_events_once`'s `let _ = state.events_tx.send(event);` → `state.channels.lock().unwrap().dispatch(&event);`, and the test module's own `AppState { events_tx, ... }` literals in `revoked_remote_websocket_cannot_receive_or_mutate` → `channels: Arc::new(Mutex::new(ChannelRegistry::default())),` (drop that test's local `let (events_tx, _) = broadcast::channel(256);` line and its later `state.events_tx.send(server_event)` call, which becomes `state.channels.lock().unwrap().dispatch(&server_event);`).

Now rewrite `websocket_session` to subscribe per-socket and honor the subscribe control frame:

```rust
async fn websocket_session(socket: WebSocket, state: AppState, last_seq: u64, token: String) {
    let (mut sender, mut receiver) = socket.split();

    if require_token(&state, &token).is_err() {
        return;
    }

    if let Ok(events) = state.store.list_events_since(last_seq) {
        for event in events {
            if require_token(&state, &token).is_err() {
                return;
            }
            let Ok(text) = serde_json::to_string(&event) else {
                continue;
            };
            if sender.send(Message::Text(text)).await.is_err() {
                return;
            }
        }
    }

    // Subscription state for this socket: which rooms it wants, and its own
    // actor's unicast channel (always included once known). Starts with no
    // rooms — until the client sends a subscribe frame it only receives
    // events it happens to be the direct `to` of, once it identifies itself.
    let mut subscribed_rooms: Vec<String> = Vec::new();
    let mut self_actor: Option<String> = None;
    let mut room_rx: Vec<(String, broadcast::Receiver<EventEnvelope>)> = Vec::new();
    let mut actor_rx: Option<broadcast::Receiver<EventEnvelope>> = None;

    loop {
        // Rebuild the select set's receivers fresh each outer loop iteration
        // whenever subscriptions changed — broadcast::Receiver isn't Clone
        // in a way that lets us hold a stale set across a subscribe update,
        // so this loop re-selects over whatever is currently subscribed.
        let mut room_futs: Vec<_> = room_rx.iter_mut().map(|(_, rx)| Box::pin(rx.recv())).collect();
        tokio::select! {
            incoming = receiver.next() => {
                let Some(Ok(message)) = incoming else {
                    return;
                };
                if let Message::Text(text) = message {
                    let Ok(role) = require_token(&state, &token) else {
                        return;
                    };
                    let Ok(control) = serde_json::from_str::<Value>(&text) else {
                        continue;
                    };
                    match control.get("type").and_then(Value::as_str) {
                        Some("subscribe") => {
                            let rooms: Vec<String> = control
                                .get("rooms")
                                .and_then(Value::as_array)
                                .map(|arr| arr.iter().filter_map(|v| v.as_str().map(str::to_string)).collect())
                                .unwrap_or_default();
                            if let Some(actor) = control.get("actor").and_then(Value::as_str) {
                                self_actor = Some(actor.to_string());
                            }
                            subscribed_rooms = rooms;
                            let mut channels = state.channels.lock().unwrap();
                            room_rx = subscribed_rooms
                                .iter()
                                .map(|room| (room.clone(), channels.room_sender(room).subscribe()))
                                .collect();
                            actor_rx = self_actor.as_deref().map(|actor| channels.actor_sender(actor).subscribe());
                            continue;
                        }
                        Some("ping") => {
                            let t = control.get("t").cloned().unwrap_or(Value::Null);
                            let pong = json!({ "v": 1, "type": "pong", "t": t });
                            if sender.send(Message::Text(pong.to_string())).await.is_err() {
                                return;
                            }
                            continue;
                        }
                        _ => {}
                    }
                    let Ok(request) = serde_json::from_str::<WsEventRequest>(&text) else {
                        continue;
                    };
                    if request.v != 1 {
                        continue;
                    };
                    if role == "observer" {
                        continue;
                    }
                    let Ok(event) = append_event(&state, request.event) else {
                        continue;
                    };
                    let ack = json!({ "v": 1, "type": "ack", "id": event.id, "seq": event.seq });
                    if sender.send(Message::Text(ack.to_string())).await.is_err() {
                        return;
                    }
                }
            }
            received = recv_any(&mut room_futs, &mut actor_rx), if !room_futs.is_empty() || actor_rx.is_some() => {
                drop(room_futs);
                let Some(Ok(event)) = received else {
                    continue;
                };
                if require_token(&state, &token).is_err() {
                    return;
                }
                let Ok(text) = serde_json::to_string(&event) else {
                    continue;
                };
                if sender.send(Message::Text(text)).await.is_err() {
                    return;
                }
            }
        }
    }
}

/// Races every subscribed room receiver plus the actor unicast receiver
/// (if present) and returns the first event any of them produces. A plain
/// `tokio::select!` can't loop over a runtime-sized Vec of futures
/// directly, so this is a small manual select via `futures_util::future::select_all`.
async fn recv_any(
    room_futs: &mut Vec<std::pin::Pin<Box<dyn std::future::Future<Output = Result<EventEnvelope, broadcast::error::RecvError>> + Send + '_>>>,
    actor_rx: &mut Option<broadcast::Receiver<EventEnvelope>>,
) -> Option<Result<EventEnvelope, broadcast::error::RecvError>> {
    use futures_util::future::{select, Either};
    let actor_fut = actor_rx.as_mut().map(|rx| Box::pin(rx.recv()));
    match (room_futs.is_empty(), actor_fut) {
        (true, None) => None,
        (true, Some(mut a)) => Some(a.as_mut().await),
        (false, None) => {
            let (result, ..) = futures_util::future::select_all(std::mem::take(room_futs)).await;
            Some(result)
        }
        (false, Some(mut a)) => {
            let rooms = futures_util::future::select_all(std::mem::take(room_futs));
            match select(rooms, a.as_mut()).await {
                Either::Left((( result, ..), _)) => Some(result),
                Either::Right((result, _)) => Some(result),
            }
        }
    }
}
```

This `recv_any` helper is intentionally verbose rather than clever — a runtime-sized set of `broadcast::Receiver`s can't go directly into `tokio::select!`'s branch list (that macro needs a fixed number of arms known at compile time), so `select_all` from `futures_util` (already a crate dependency) is the standard way to race a `Vec` of futures. If this proves awkward in practice, an acceptable simpler alternative — note it in a comment if you take this path instead — is a single `tokio::sync::mpsc` per socket that every subscribed room/actor broadcast task forwards into, replacing the `Vec` of receivers with one `mpsc::Receiver` the outer `tokio::select!` can reference directly. Prefer that alternative if `select_all`'s ownership juggling (rebuilding `room_futs` every loop iteration) turns out to fight the borrow checker in ways that make the code hard to follow — correctness and readability here matter more than which concurrency primitive wins.

- [ ] **Step 4: Fix every existing test using the old `events_tx`/broadcast test-harness fields**

Run: `cargo build -p workbench-mesh --tests 2>&1 | tail -60` and fix each compile error — every test constructing `AppState { events_tx: ..., ... }` directly (there is at least one, in `revoked_remote_websocket_cannot_receive_or_mutate`) needs `channels: Arc::new(Mutex::new(ChannelRegistry::default()))` instead, and any place that manually sends via `state.events_tx.send(...)` needs `state.channels.lock().unwrap().dispatch(&event)`.

- [ ] **Step 5: Run the full test suite**

Run: `cargo test -p workbench-mesh 2>&1 | tail -60`
Expected: PASS — every existing WS test (`websocket_auth_replay_versioned_append_ack_and_broadcast`, `revoked_remote_websocket_cannot_receive_or_mutate`, etc.) still passes because a socket that never sends a `subscribe` frame but is the direct addressee of an event still receives it once `self_actor` matches — **check this carefully**: the pre-existing tests never send a subscribe frame at all, so they rely on room-broadcast delivery. Since `websocket_auth_replay_versioned_append_ack_and_broadcast`'s second socket expects to receive a `repo:mesh-service` broadcast without ever subscribing, that test will now fail unless it's updated to send a `subscribe` frame for that room first. **Update that existing test** (and any other pre-existing test relying on receiving live broadcast traffic without subscribing) to send `{"v":1,"type":"subscribe","rooms":["<room>"]}` right after connecting, before the event that traffic checks for is posted.

- [ ] **Step 6: Commit**

```bash
git add crates/workbench-mesh/src/server.rs
git commit -m "feat(mesh): replace global WS broadcast with per-room/per-actor subscription channels"
```

---

### Task 6: Server — micro-batch live WS pushes (~16ms)

**Files:**
- Modify: `crates/workbench-mesh/src/server.rs`
- Test: `crates/workbench-mesh/src/server.rs` (inline)

**Interfaces:**
- Consumes: the subscription plumbing from Task 5.
- Produces: live (post-replay) pushes now arrive as `{"v":1,"type":"batch","events":[...]}` frames instead of one frame per event. Replay frames (the catch-up-on-connect loop) are unchanged — they stay one envelope per frame, since that path already has a passing contract test.

- [ ] **Step 1: Write the failing test**

```rust
    #[tokio::test]
    async fn concurrent_events_arrive_batched_in_one_frame() {
        let project = TempDir::new().unwrap();
        let home = TempDir::new().unwrap();
        write_project_config(project.path(), "Mesh Service");
        auth::bootstrap(project.path(), Some(home.path().to_path_buf())).unwrap();
        let owner_token =
            auth::local_project_token(project.path(), Some(home.path().to_path_buf())).unwrap();

        let server = tokio::spawn(serve(ServeOptions {
            project_root: project.path().to_path_buf(),
            home: Some(home.path().to_path_buf()),
            bind: "local".to_string(),
            port: 0,
            pid_file: None,
            started_by: None,
        }));
        let metadata = wait_for_metadata(project.path()).await;

        let (mut socket, _) = connect_async(format!(
            "ws://{}:{}/ws?token={}&last_seq=0",
            metadata.host, metadata.port, metadata.local_token
        ))
        .await
        .unwrap();
        socket
            .send(ClientMessage::Text(
                json!({ "v": 1, "type": "subscribe", "rooms": ["repo:mesh-service"] }).to_string(),
            ))
            .await
            .unwrap();
        sleep(Duration::from_millis(50)).await;

        let client = Client::new();
        let base = format!("http://{}:{}", metadata.host, metadata.port);
        for i in 0..5 {
            client
                .post(format!("{base}/api/events"))
                .bearer_auth(&owner_token)
                .json(&json!({ "type": "message.sent", "room": "repo:mesh-service", "from": "session:lead", "payload": { "idx": i } }))
                .send()
                .await
                .unwrap()
                .error_for_status()
                .unwrap();
        }

        let batch = read_ws_json(&mut socket).await;
        assert_eq!(batch["type"], "batch");
        let events = batch["events"].as_array().unwrap();
        assert!(events.len() >= 2, "expected multiple events coalesced into one frame, got {}", events.len());

        server.abort();
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cargo test -p workbench-mesh server::tests::concurrent_events_arrive_batched_in_one_frame 2>&1 | tail -30`
Expected: FAIL — today's `websocket_session` forwards each event as its own frame immediately.

- [ ] **Step 3: Add a batching buffer to the live-push arm**

Replace the live-push arm of `websocket_session`'s `tokio::select!` (the `recv_any` branch added in Task 5) with a version that buffers for ~16ms before flushing:

```rust
            received = recv_any(&mut room_futs, &mut actor_rx), if !room_futs.is_empty() || actor_rx.is_some() => {
                drop(room_futs);
                let Some(Ok(first_event)) = received else {
                    continue;
                };
                if require_token(&state, &token).is_err() {
                    return;
                }
                let mut batch = vec![first_event];
                let deadline = tokio::time::Instant::now() + Duration::from_millis(16);
                loop {
                    let mut more_futs: Vec<_> = subscribed_rooms
                        .iter()
                        .filter_map(|room| room_rx.iter_mut().find(|(r, _)| r == room))
                        .map(|(_, rx)| Box::pin(rx.recv()))
                        .collect();
                    tokio::select! {
                        _ = tokio::time::sleep_until(deadline) => break,
                        received = recv_any(&mut more_futs, &mut actor_rx) => {
                            drop(more_futs);
                            if let Some(Ok(event)) = received { batch.push(event); } else { break; }
                        }
                    }
                }
                let Ok(text) = serde_json::to_string(&json!({ "v": 1, "type": "batch", "events": batch })) else {
                    continue;
                };
                if sender.send(Message::Text(text)).await.is_err() {
                    return;
                }
            }
```

This nested-loop shape (rebuild `more_futs` from `room_rx` each pass) is the same pattern Task 5 already established for the outer loop — reuse it rather than inventing a second mechanism. If Task 5 ended up using the `mpsc`-per-socket alternative instead of `select_all`, this batching step is simpler: `while let Ok(event) = tokio::time::timeout_at(deadline, rx.recv()).await { ... }` around the single `mpsc::Receiver`. Adapt to whichever primitive Task 5 actually landed on — the important behavior is: buffer for a 16ms window after the first event, flush whatever accumulated as one `batch` frame.

- [ ] **Step 4: Run tests to verify they pass**

Run: `cargo test -p workbench-mesh 2>&1 | tail -40`
Expected: PASS — `concurrent_events_arrive_batched_in_one_frame` passes; every other WS test (which reads one event per `read_ws_json` call) must be checked against the new batch framing — **update `read_ws_json`** (the test helper used throughout `server.rs`'s test module) to unwrap a `batch` frame's first event transparently so existing single-event assertions keep working:

```rust
    async fn read_ws_json(
        socket: &mut tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>,
    ) -> Value {
        loop {
            let msg = socket.next().await.unwrap().unwrap();
            let ClientMessage::Text(text) = msg else { continue };
            let value: Value = serde_json::from_str(&text).unwrap();
            if value["type"] == "batch" {
                return value["events"][0].clone();
            }
            return value;
        }
    }
```

(Find the existing `read_ws_json` definition first — `grep -n "fn read_ws_json" crates/workbench-mesh/src/server.rs` — and modify it in place rather than adding a duplicate.)

- [ ] **Step 5: Commit**

```bash
git add crates/workbench-mesh/src/server.rs
git commit -m "feat(mesh): micro-batch live WS pushes into 16ms-coalesced frames"
```

---

### Task 7: Server — pagination endpoint

**Files:**
- Modify: `crates/workbench-mesh/src/server.rs`
- Test: `crates/workbench-mesh/src/server.rs` (inline)

**Interfaces:**
- Consumes: `MeshStore::list_events_page` (Task 3).
- Produces: `GET /api/events?room=<room>&before=<seq>&limit=<n>` → `{"events": [...]}` (newest-first). Existing `GET /api/events?since=<seq>` behavior (forward-scan, ascending) is untouched — this adds new optional query params to the same handler rather than a new route, since both share auth/shape.

- [ ] **Step 1: Write the failing test**

```rust
    #[tokio::test]
    async fn api_events_supports_room_before_limit_pagination() {
        let project = TempDir::new().unwrap();
        let home = TempDir::new().unwrap();
        write_project_config(project.path(), "Mesh Service");
        auth::bootstrap(project.path(), Some(home.path().to_path_buf())).unwrap();
        let owner_token =
            auth::local_project_token(project.path(), Some(home.path().to_path_buf())).unwrap();

        let server = tokio::spawn(serve(ServeOptions {
            project_root: project.path().to_path_buf(),
            home: Some(home.path().to_path_buf()),
            bind: "local".to_string(),
            port: 0,
            pid_file: None,
            started_by: None,
        }));
        let metadata = wait_for_metadata(project.path()).await;
        let base = format!("http://{}:{}", metadata.host, metadata.port);
        let client = Client::new();

        for i in 0..5 {
            client
                .post(format!("{base}/api/events"))
                .bearer_auth(&owner_token)
                .json(&json!({ "type": "message.sent", "room": "repo:mesh-service", "from": "session:lead", "payload": { "idx": i } }))
                .send()
                .await
                .unwrap()
                .error_for_status()
                .unwrap();
        }

        let page: Value = client
            .get(format!("{base}/api/events?room=repo:mesh-service&limit=2"))
            .bearer_auth(&owner_token)
            .send()
            .await
            .unwrap()
            .error_for_status()
            .unwrap()
            .json()
            .await
            .unwrap();
        let events = page["events"].as_array().unwrap();
        assert_eq!(events.len(), 2);
        assert_eq!(events[0]["payload"]["idx"], 4);
        assert_eq!(events[1]["payload"]["idx"], 3);

        server.abort();
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cargo test -p workbench-mesh server::tests::api_events_supports_room_before_limit_pagination 2>&1 | tail -30`
Expected: FAIL — `EventsQuery` has no `room`/`before`/`limit` fields; the handler always does a forward scan.

- [ ] **Step 3: Extend `EventsQuery` and `api_events`**

```rust
#[derive(Debug, Deserialize)]
struct EventsQuery {
    since: Option<u64>,
    room: Option<String>,
    before: Option<u64>,
    limit: Option<usize>,
}
```

```rust
async fn api_events(
    State(state): State<AppState>,
    headers: HeaderMap,
    Query(query): Query<EventsQuery>,
) -> Result<Json<Value>, ApiError> {
    require_bearer(&state, &headers)?;
    let events = if query.room.is_some() || query.before.is_some() || query.limit.is_some() {
        state
            .store
            .list_events_page(query.room.as_deref(), query.before, query.limit.unwrap_or(50))?
    } else {
        state.store.list_events_since(query.since.unwrap_or(0))?
    };
    Ok(Json(json!({ "events": events })))
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cargo test -p workbench-mesh 2>&1 | tail -40`
Expected: PASS — new pagination test green, existing `since`-based `api_events` usage (state loading, etc.) unaffected since it takes the untouched branch.

- [ ] **Step 5: Commit**

```bash
git add crates/workbench-mesh/src/server.rs
git commit -m "feat(mesh): add room/before/limit pagination to GET /api/events"
```

---

### Task 8: Server — app-level ping/pong already lands with Task 5

Task 5's `websocket_session` rewrite already added the `Some("ping") => { ... pong ... }` control-frame arm. This task is just verification + a dedicated test, kept separate because it's an independently reviewable behavior (a reviewer could accept Task 5's subscription filtering while rejecting the ping/pong addition, or vice versa).

**Files:**
- Test only: `crates/workbench-mesh/src/server.rs` (inline)

- [ ] **Step 1: Write the test**

```rust
    #[tokio::test]
    async fn app_level_ping_receives_matching_pong() {
        let project = TempDir::new().unwrap();
        let home = TempDir::new().unwrap();
        write_project_config(project.path(), "Mesh Service");
        auth::bootstrap(project.path(), Some(home.path().to_path_buf())).unwrap();

        let server = tokio::spawn(serve(ServeOptions {
            project_root: project.path().to_path_buf(),
            home: Some(home.path().to_path_buf()),
            bind: "local".to_string(),
            port: 0,
            pid_file: None,
            started_by: None,
        }));
        let metadata = wait_for_metadata(project.path()).await;

        let (mut socket, _) = connect_async(format!(
            "ws://{}:{}/ws?token={}&last_seq=0",
            metadata.host, metadata.port, metadata.local_token
        ))
        .await
        .unwrap();
        socket
            .send(ClientMessage::Text(json!({ "v": 1, "type": "ping", "t": 12345 }).to_string()))
            .await
            .unwrap();
        let pong = read_ws_json(&mut socket).await;
        assert_eq!(pong["type"], "pong");
        assert_eq!(pong["t"], 12345);

        server.abort();
    }
```

- [ ] **Step 2: Run test**

Run: `cargo test -p workbench-mesh server::tests::app_level_ping_receives_matching_pong 2>&1 | tail -20`
Expected: PASS (implementation already landed in Task 5). If it fails, fix the `Some("ping")` arm in `websocket_session` before proceeding — do not move on with a red test.

- [ ] **Step 3: Commit**

```bash
git add crates/workbench-mesh/src/server.rs
git commit -m "test(mesh): cover app-level ping/pong control frame"
```

---

### Task 9: CLI — `--ack-of` on `activity` (message.read) and a dedicated ack helper (message.delivered)

**Files:**
- Modify: `crates/workbench-mesh/src/client.rs`
- Modify: `crates/workbench-mesh/src/main.rs`
- Test: `crates/workbench-mesh/src/client.rs` (inline)

**Interfaces:**
- Produces: `client::set_activity(..., ack_of: Option<u64>)` now emits `message.read{ack_of}` when `ack_of` is `Some` (instead of `presence.heartbeat{activity}`); `client::send_ack(project_root, home, event_type: &str, ack_of: u64, room: &str, from: Option<&str>) -> Result<()>` for `message.delivered`.

- [ ] **Step 1: Write the failing tests**

Add to `client.rs`'s test module:

```rust
    #[tokio::test]
    async fn activity_with_ack_of_emits_message_read() {
        let project = TempDir::new().unwrap();
        let home = TempDir::new().unwrap();
        write_project_config(project.path(), "Mesh Client");
        write_project_credential(home.path(), "worker.cred", "mesh-client", "worker");

        let sent = MeshStore::open(project.path())
            .unwrap()
            .append_event("message.sent", "repo:workbench", "session:lead", Some("session:worker"), json!({ "text": "hi" }))
            .unwrap();

        set_activity(
            project.path().to_path_buf(),
            Some(home.path().to_path_buf()),
            "reading".to_string(),
            Some("session:worker".to_string()),
            Some(sent.seq),
        )
        .await
        .unwrap();

        let events = MeshStore::open(project.path()).unwrap().list_events_since(0).unwrap();
        let ack = events.iter().find(|e| e.event_type == "message.read").unwrap();
        assert_eq!(ack.ack_of, Some(sent.seq));
        assert_eq!(ack.room, "repo:workbench");
        assert_eq!(ack.from, "session:worker");
    }

    #[tokio::test]
    async fn activity_without_ack_of_still_emits_plain_heartbeat() {
        let project = TempDir::new().unwrap();
        let home = TempDir::new().unwrap();
        write_project_config(project.path(), "Mesh Client");
        write_project_credential(home.path(), "worker.cred", "mesh-client", "worker");

        set_activity(
            project.path().to_path_buf(),
            Some(home.path().to_path_buf()),
            "typing".to_string(),
            Some("session:worker".to_string()),
            None,
        )
        .await
        .unwrap();

        let events = MeshStore::open(project.path()).unwrap().list_events_since(0).unwrap();
        assert_eq!(events[0].event_type, "presence.heartbeat");
        assert_eq!(events[0].payload["activity"], "typing");
    }

    #[tokio::test]
    async fn send_ack_emits_message_delivered_with_ack_of() {
        let project = TempDir::new().unwrap();
        let home = TempDir::new().unwrap();
        write_project_config(project.path(), "Mesh Client");
        write_project_credential(home.path(), "worker.cred", "mesh-client", "worker");

        let sent = MeshStore::open(project.path())
            .unwrap()
            .append_event("message.sent", "repo:workbench", "session:lead", Some("session:worker"), json!({ "text": "hi" }))
            .unwrap();

        super::send_ack(
            project.path().to_path_buf(),
            Some(home.path().to_path_buf()),
            "message.delivered",
            sent.seq,
            "repo:workbench",
            Some("session:worker"),
        )
        .await
        .unwrap();

        let events = MeshStore::open(project.path()).unwrap().list_events_since(0).unwrap();
        let ack = events.iter().find(|e| e.event_type == "message.delivered").unwrap();
        assert_eq!(ack.ack_of, Some(sent.seq));
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cargo test -p workbench-mesh client:: 2>&1 | tail -40`
Expected: FAIL — `set_activity`'s signature doesn't take `ack_of` yet; `send_ack` doesn't exist.

- [ ] **Step 3: Implement**

Modify `set_activity`:

```rust
pub async fn set_activity(
    project_root: PathBuf,
    home: Option<PathBuf>,
    state: String,
    from: Option<String>,
    ack_of: Option<u64>,
) -> Result<()> {
    let actor = resolve_actor(from.as_deref());
    let event = match ack_of {
        Some(seq) => {
            let referenced = referenced_event(&project_root, home.clone(), seq).await?;
            append_or_post_ack(&project_root, home, "message.read", &referenced.room, &actor, seq).await?
        }
        None => {
            append_or_post_event(
                &project_root,
                home,
                "presence.heartbeat",
                "presence",
                &actor,
                None,
                json!({ "activity": state }),
            )
            .await?
        }
    };
    println!("activity: {} seq={}", state, event.seq);
    Ok(())
}

/// Emits a `message.delivered`/`message.read` receipt for `ack_of`, in the
/// same room as the event it acknowledges — required by `validate_ack`.
pub async fn send_ack(
    project_root: PathBuf,
    home: Option<PathBuf>,
    event_type: &str,
    ack_of: u64,
    room: &str,
    from: Option<&str>,
) -> Result<()> {
    let actor = resolve_actor(from);
    let event = append_or_post_ack(&project_root, home, event_type, room, &actor, ack_of).await?;
    println!("ack: {event_type} seq={}", event.seq);
    Ok(())
}

async fn referenced_event(
    project_root: &std::path::Path,
    home: Option<PathBuf>,
    seq: u64,
) -> Result<crate::protocol::EventEnvelope> {
    auth::require_local_project_credential(project_root, home)?;
    MeshStore::open(project_root)?
        .get_event(seq)?
        .ok_or_else(|| anyhow::anyhow!("no event with seq {seq}"))
}

async fn append_or_post_ack(
    project_root: &std::path::Path,
    home: Option<PathBuf>,
    event_type: &str,
    room: &str,
    from: &str,
    ack_of: u64,
) -> Result<crate::protocol::EventEnvelope> {
    auth::require_local_mutating_project_credential(project_root, home.clone())?;
    if let Ok(metadata) = read_server_metadata(project_root) {
        if metadata.mode == "remote" {
            let token = auth::local_mutating_project_token(project_root, home)?;
            let response = Client::new()
                .post(format!("{}/api/events", base_url(&metadata)))
                .bearer_auth(&token)
                .json(&json!({
                    "type": event_type,
                    "room": room,
                    "from": from,
                    "ack_of": ack_of,
                    "payload": {},
                }))
                .send()
                .await
                .context("post remote ack event")?
                .error_for_status()
                .context("remote ack event rejected")?;
            return response.json().await.context("parse remote ack event");
        }
    }
    MeshStore::open(project_root)?.append_event_with_ack(event_type, room, from, None, json!({}), Some(ack_of))
}
```

- [ ] **Step 4: Update every call site of `set_activity`**

`main.rs`'s `Command::Activity(args) => client::set_activity(args.target, args.home, args.state, args.as_actor).await` becomes:

```rust
        Command::Activity(args) => {
            client::set_activity(args.target, args.home, args.state, args.as_actor, args.ack_of).await
        }
```

`ActivityArgs` gains a field:

```rust
#[derive(Debug, Args)]
struct ActivityArgs {
    #[arg(long)]
    target: PathBuf,
    #[arg(long)]
    home: Option<PathBuf>,
    /// reading | typing | idle
    state: String,
    #[arg(long = "as")]
    as_actor: Option<String>,
    /// seq of the message this activity update acknowledges. When set,
    /// posts a message.read receipt instead of a plain presence heartbeat.
    #[arg(long = "ack-of")]
    ack_of: Option<u64>,
}
```

Add an `Ack(AckArgs)` subcommand for `send_ack`:

```rust
#[derive(Debug, Args)]
struct AckArgs {
    #[arg(long)]
    target: PathBuf,
    #[arg(long)]
    home: Option<PathBuf>,
    /// message.delivered | message.read
    #[arg(long = "type")]
    event_type: String,
    #[arg(long = "ack-of")]
    ack_of: u64,
    #[arg(long)]
    room: String,
    #[arg(long = "as")]
    as_actor: Option<String>,
}
```

Add `Ack(AckArgs),` to the `Command` enum, and in `main`'s match:

```rust
        Command::Ack(args) => {
            client::send_ack(args.target, args.home, &args.event_type, args.ack_of, &args.room, args.as_actor.as_deref()).await
        }
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cargo test -p workbench-mesh 2>&1 | tail -60`
Expected: PASS — full crate green.

- [ ] **Step 6: Commit**

```bash
git add crates/workbench-mesh/src/client.rs crates/workbench-mesh/src/main.rs
git commit -m "feat(mesh): add --ack-of on activity and a dedicated ack CLI command"
```

---

### Task 10: `listen` connector — connect, subscribe, ack, FIFO wake

**Files:**
- Modify: `crates/workbench-mesh/Cargo.toml`
- Create: `crates/workbench-mesh/src/listen.rs`
- Modify: `crates/workbench-mesh/src/lib.rs` (register the module)
- Modify: `crates/workbench-mesh/src/main.rs` (wire `Listen` subcommand)
- Test: `crates/workbench-mesh/src/listen.rs` (inline)

**Interfaces:**
- Consumes: `resolve_actor`-style identity resolution (mirror the pattern in `client.rs`, don't import private items across modules — duplicate the small resolution helper or make it `pub(crate)` in `client.rs` and import it).
- Produces: `pub async fn run(project_root: PathBuf, home: Option<PathBuf>, actor: String) -> anyhow::Result<()>` — the connector's main loop (Task 11 adds reconnect/backoff around this).

This task covers the core connect→subscribe→ack→pipe loop for a single successful connection (no reconnect logic yet — that's Task 11, kept separate because it's independently reviewable: a reviewer could accept "does it ack correctly" while still having concerns about "does it reconnect correctly").

- [ ] **Step 1: Move `tokio-tungstenite` to production dependencies**

Modify `crates/workbench-mesh/Cargo.toml`:

```toml
[dependencies]
anyhow = "1"
axum = { version = "0.7", features = ["ws"] }
base64 = "0.22"
clap = { version = "4", features = ["derive"] }
fs2 = "0.4"
futures-util = "0.3"
hmac = "0.12"
rand = "0.8"
reqwest = { version = "0.12", default-features = false, features = ["json", "rustls-tls"] }
serde = { version = "1", features = ["derive"] }
serde_json = "1"
sha2 = "0.10"
time = { version = "0.3", features = ["formatting", "parsing", "serde"] }
tokio = { version = "1", features = ["macros", "rt-multi-thread", "signal", "time", "fs", "net", "sync", "io-std", "io-util"] }
tokio-tungstenite = "0.24"
uuid = { version = "1", features = ["v7", "serde"] }

[dev-dependencies]
tempfile = "3"
```

(Just move the line — `tokio-tungstenite` stays version `"0.24"`, matching what dev-dependencies already pinned, so the WS client behavior tests already validated against stays identical.)

- [ ] **Step 2: Write the failing test**

Create `crates/workbench-mesh/src/listen.rs`:

```rust
use std::path::{Path, PathBuf};

use anyhow::{Context, Result};
use futures_util::{SinkExt, StreamExt};
use serde_json::{json, Value};
use tokio_tungstenite::tungstenite::Message;

use crate::server::{read_server_metadata, ServerMetadata};

/// A single inbound message the connector acked and surfaced — the same
/// shape `mesh-inbox-wait.sh` prints today, kept stable so the harness-facing
/// wrapper doesn't need to change its parsing.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct InboxHit {
    pub seq: u64,
    pub room: String,
    pub from: String,
    pub text: String,
}

fn ws_url(metadata: &ServerMetadata, token: &str) -> String {
    format!("ws://{}:{}/ws?token={token}&last_seq=0", metadata.host, metadata.port)
}

fn is_inbound_for(actor: &str, event: &Value) -> bool {
    let event_type = event.get("type").and_then(Value::as_str).unwrap_or("");
    if !(event_type.starts_with("message.") || event_type == "task.handoff") {
        return false;
    }
    if event.get("from").and_then(Value::as_str) == Some(actor) {
        return false; // never ack our own echo
    }
    let to_match = event.get("to").and_then(Value::as_str) == Some(actor);
    let room_match = event.get("room").and_then(Value::as_str) == Some(actor)
        || event
            .get("room")
            .and_then(Value::as_str)
            .map(|r| r == "team" || r.starts_with("repo:"))
            .unwrap_or(false);
    to_match || room_match
}

fn extract_text(event: &Value) -> String {
    let payload = event.get("payload").cloned().unwrap_or(json!({}));
    payload
        .get("text")
        .or_else(|| payload.get("question"))
        .or_else(|| payload.get("task_id"))
        .and_then(Value::as_str)
        .unwrap_or("?")
        .to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn is_inbound_for_matches_direct_and_room_targets_but_not_self() {
        let direct = json!({ "type": "message.sent", "from": "session:lead", "to": "session:worker", "room": "direct:session:worker" });
        assert!(is_inbound_for("session:worker", &direct));

        let room = json!({ "type": "message.sent", "from": "session:lead", "room": "repo:workbench" });
        assert!(is_inbound_for("session:worker", &room));

        let echo = json!({ "type": "message.sent", "from": "session:worker", "to": "session:lead", "room": "direct:session:lead" });
        assert!(!is_inbound_for("session:worker", &echo));

        let unrelated = json!({ "type": "presence.heartbeat", "from": "session:lead", "room": "presence" });
        assert!(!is_inbound_for("session:worker", &unrelated));
    }

    #[test]
    fn extract_text_prefers_text_then_question_then_task_id() {
        assert_eq!(extract_text(&json!({ "payload": { "text": "hi" } })), "hi");
        assert_eq!(extract_text(&json!({ "payload": { "question": "status?" } })), "status?");
        assert_eq!(extract_text(&json!({ "payload": { "task_id": "wb-1" } })), "wb-1");
        assert_eq!(extract_text(&json!({ "payload": {} })), "?");
    }

    #[test]
    fn ws_url_targets_the_ws_endpoint_with_token_and_zero_last_seq() {
        let metadata = ServerMetadata {
            mode: "local".to_string(),
            host: "127.0.0.1".to_string(),
            port: 47321,
            hostname: "h".to_string(),
            mdns: "h.local".to_string(),
            lan_ips: vec![],
            local_token: "tok".to_string(),
            started_by: "unknown".to_string(),
            started_at: String::new(),
        };
        assert_eq!(ws_url(&metadata, "tok"), "ws://127.0.0.1:47321/ws?token=tok&last_seq=0");
    }
}
```

- [ ] **Step 3: Run tests to verify they pass (pure functions first)**

Run: `cargo test -p workbench-mesh listen:: 2>&1 | tail -30`
Expected: PASS for the three pure-function tests above — this validates the filtering/parsing logic in isolation before wiring the actual network loop, which is much harder to unit test deterministically.

- [ ] **Step 4: Add the connection loop and FIFO writer**

Append to `listen.rs`:

```rust
/// Connects once, subscribes to the actor's own channel plus its
/// coordination rooms, and for every inbound event: acks it immediately
/// (`message.delivered`) and writes it to the actor's FIFO so the
/// harness-facing blocking reader wakes instantly instead of polling.
/// Returns when the connection drops — the caller (Task 11) wraps this in
/// a reconnect loop.
pub async fn run_once(project_root: &Path, home: Option<PathBuf>, actor: &str) -> Result<()> {
    let metadata = read_server_metadata(project_root).context("read server metadata")?;
    let token = crate::auth::local_mutating_project_token(project_root, home.clone())
        .context("resolve mutating token")?;
    let url = ws_url(&metadata, &token);
    let (ws_stream, _) = tokio_tungstenite::connect_async(&url)
        .await
        .with_context(|| format!("connect to {url}"))?;
    let (mut write, mut read) = ws_stream.split();

    let subscribe = json!({ "v": 1, "type": "subscribe", "rooms": ["team", format!("repo:{}", project_slug(project_root)), actor], "actor": actor });
    write
        .send(Message::Text(subscribe.to_string()))
        .await
        .context("send subscribe frame")?;

    let fifo_path = ensure_fifo(project_root, actor)?;

    while let Some(message) = read.next().await {
        let message = message.context("read ws frame")?;
        let Message::Text(text) = message else { continue };
        let Ok(envelope) = serde_json::from_str::<Value>(&text) else { continue };
        let events: Vec<Value> = if envelope.get("type") == Some(&Value::String("batch".to_string())) {
            envelope.get("events").and_then(Value::as_array).cloned().unwrap_or_default()
        } else {
            vec![envelope]
        };
        for event in events {
            if !is_inbound_for(actor, &event) {
                continue;
            }
            let Some(seq) = event.get("seq").and_then(Value::as_u64) else { continue };
            let room = event.get("room").and_then(Value::as_str).unwrap_or("").to_string();
            let from = event.get("from").and_then(Value::as_str).unwrap_or("").to_string();
            let text = extract_text(&event);

            let ack = json!({
                "v": 1,
                "type": "message.delivered",
                "room": room,
                "from": actor,
                "ack_of": seq,
                "payload": {},
            });
            if let Err(err) = write.send(Message::Text(ack.to_string())).await {
                eprintln!("listen: failed to send ack for seq {seq}: {err}");
            }

            let hit = InboxHit { seq, room, from, text };
            if let Err(err) = write_fifo(&fifo_path, &hit) {
                eprintln!("listen: failed to write inbox pipe: {err:#}");
            }
        }
    }
    Ok(())
}

fn project_slug(project_root: &Path) -> String {
    project_root
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("workbench")
        .to_string()
}

fn ensure_fifo(project_root: &Path, actor: &str) -> Result<PathBuf> {
    let dir = project_root.join(".workbench/mesh");
    std::fs::create_dir_all(&dir).with_context(|| format!("create {}", dir.display()))?;
    let safe_actor = actor.replace([':', '/'], "-");
    let path = dir.join(format!("inbox-{safe_actor}.fifo"));
    #[cfg(unix)]
    {
        if !path.exists() {
            let cpath = std::ffi::CString::new(path.to_string_lossy().as_bytes())
                .context("fifo path contains a NUL byte")?;
            let result = unsafe { libc_mkfifo(cpath.as_ptr(), 0o600) };
            if result != 0 {
                anyhow::bail!("mkfifo({}) failed", path.display());
            }
        }
    }
    Ok(path)
}

#[cfg(unix)]
extern "C" {
    #[link_name = "mkfifo"]
    fn libc_mkfifo(path: *const std::os::raw::c_char, mode: u32) -> i32;
}

fn write_fifo(path: &Path, hit: &InboxHit) -> Result<()> {
    use std::io::Write;
    // Opening a FIFO for write blocks until a reader is attached — spawn it
    // on a blocking thread so one slow/absent reader never stalls the
    // connector's main event loop (which must keep acking other messages).
    let path = path.to_path_buf();
    let line = format!("seq={} room={} from={}: {}\n", hit.seq, hit.room, hit.from, hit.text);
    std::thread::spawn(move || {
        if let Ok(mut file) = std::fs::OpenOptions::new().write(true).open(&path) {
            let _ = file.write_all(line.as_bytes());
        }
    });
    Ok(())
}
```

`ensure_fifo`'s raw `mkfifo` FFI avoids adding a new crate dependency (no `nix`/`libc` crate in the workspace today) for a single syscall; if a `libc` dependency is later added to the workspace for other reasons, switch this to `libc::mkfifo` and drop the local `extern "C"` block. Guard the whole `ensure_fifo`/`write_fifo` pair behind `#[cfg(unix)]` at the call site in `run_once` too, with a `#[cfg(not(unix))]` fallback that logs "listen: FIFO wake unsupported on this platform, falling back to no wake pipe" and skips `write_fifo` — the connector should still ack messages even where the pipe isn't available.

- [ ] **Step 5: Register the module and wire the CLI**

Add to `crates/workbench-mesh/src/lib.rs` (find the existing `pub mod` list and add alongside):

```rust
pub mod listen;
```

Add to `main.rs`:

```rust
    Listen(ListenArgs),
```

```rust
#[derive(Debug, Args)]
struct ListenArgs {
    #[arg(long)]
    target: PathBuf,
    #[arg(long)]
    home: Option<PathBuf>,
    #[arg(long = "as")]
    as_actor: Option<String>,
}
```

```rust
        Command::Listen(args) => {
            let actor = args.as_actor.unwrap_or_else(|| {
                std::env::var("WORKBENCH_MESH_ACTOR").unwrap_or_else(|_| "session:lead".to_string())
            });
            workbench_mesh::listen::run_once(&args.target, args.home, &actor).await
        }
```

- [ ] **Step 6: Run the full test suite**

Run: `cargo test -p workbench-mesh 2>&1 | tail -60` and `cargo build -p workbench-mesh --release 2>&1 | tail -30`
Expected: PASS, and the release binary builds cleanly with the new `listen` subcommand available (`./target/release/workbench-mesh listen --help`).

- [ ] **Step 7: Commit**

```bash
git add crates/workbench-mesh/Cargo.toml crates/workbench-mesh/src/listen.rs crates/workbench-mesh/src/lib.rs crates/workbench-mesh/src/main.rs
git commit -m "feat(mesh): add workbench-mesh listen connector — connect, subscribe, ack, FIFO wake"
```

---

### Task 11: `listen` connector — reconnect/backoff + native ping/pong RTT

**Files:**
- Modify: `crates/workbench-mesh/src/listen.rs`
- Modify: `crates/workbench-mesh/src/main.rs`
- Test: `crates/workbench-mesh/src/listen.rs` (inline)

**Interfaces:**
- Produces: `pub async fn run(project_root: PathBuf, home: Option<PathBuf>, actor: String) -> Result<()>` — wraps `run_once` in the reconnect loop; `fn backoff_delay(attempt: u32) -> std::time::Duration` — pure, testable backoff calculation.

- [ ] **Step 1: Write the failing test**

```rust
    #[test]
    fn backoff_delay_starts_fast_and_caps_at_five_seconds() {
        assert_eq!(super::backoff_delay(0), std::time::Duration::from_millis(250));
        assert!(super::backoff_delay(1) > std::time::Duration::from_millis(250));
        assert!(super::backoff_delay(10) <= std::time::Duration::from_secs(5) + std::time::Duration::from_millis(500));
        // every call must stay within a sane floor even with jitter
        assert!(super::backoff_delay(10) >= std::time::Duration::from_secs(2));
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cargo test -p workbench-mesh listen::tests::backoff_delay_starts_fast_and_caps_at_five_seconds 2>&1 | tail -20`
Expected: FAIL — `backoff_delay` doesn't exist.

- [ ] **Step 3: Implement `backoff_delay` and the reconnect loop**

```rust
/// First retry is fast (covers the common case — a blip); subsequent
/// retries back off exponentially, capped, with jitter so many actors
/// reconnecting after a server restart don't all hammer it in lockstep.
fn backoff_delay(attempt: u32) -> std::time::Duration {
    if attempt == 0 {
        return std::time::Duration::from_millis(250);
    }
    let base_ms = 250u64.saturating_mul(1u64 << attempt.min(6));
    let capped_ms = base_ms.min(5_000);
    let jitter_ms = (capped_ms / 5).max(1);
    let jitter = (attempt as u64 * 97) % jitter_ms; // deterministic pseudo-jitter, no rand dependency needed here
    std::time::Duration::from_millis(capped_ms + jitter)
}

/// Reconnect loop around `run_once`: every dropped connection is retried
/// with backoff rather than exiting, so a `listen` process started once at
/// session start survives server restarts for the rest of the dev session.
pub async fn run(project_root: PathBuf, home: Option<PathBuf>, actor: String) -> Result<()> {
    let mut attempt = 0u32;
    loop {
        match run_once(&project_root, home.clone(), &actor).await {
            Ok(()) => {
                eprintln!("listen: connection closed cleanly, reconnecting");
                attempt = 0;
            }
            Err(err) => {
                eprintln!("listen: connection error: {err:#}, reconnecting");
                attempt = attempt.saturating_add(1);
            }
        }
        tokio::time::sleep(backoff_delay(attempt)).await;
    }
}
```

- [ ] **Step 4: Wire native WS ping/pong for RTT**

`tokio-tungstenite` surfaces control frames through the same `Message` enum `run_once` already reads (`Message::Ping`/`Message::Pong`), and the underlying library auto-replies to `Ping` with `Pong` — so RTT measurement is the connector's own responsibility: send a `Ping` periodically and time the matching `Pong`. Modify `run_once`'s read loop to interleave a ping ticker:

```rust
    let fifo_path = ensure_fifo(project_root, actor)?;
    let mut ping_interval = tokio::time::interval(std::time::Duration::from_secs(5));
    let mut last_ping_sent: Option<tokio::time::Instant> = None;

    loop {
        tokio::select! {
            _ = ping_interval.tick() => {
                last_ping_sent = Some(tokio::time::Instant::now());
                if write.send(Message::Ping(vec![])).await.is_err() {
                    break;
                }
            }
            message = read.next() => {
                let Some(message) = message else { break };
                let message = message.context("read ws frame")?;
                match message {
                    Message::Pong(_) => {
                        if let Some(sent) = last_ping_sent.take() {
                            let rtt = sent.elapsed();
                            eprintln!("listen: rtt={}ms", rtt.as_millis());
                        }
                        continue;
                    }
                    Message::Text(text) => {
                        let Ok(envelope) = serde_json::from_str::<Value>(&text) else { continue };
                        let events: Vec<Value> = if envelope.get("type") == Some(&Value::String("batch".to_string())) {
                            envelope.get("events").and_then(Value::as_array).cloned().unwrap_or_default()
                        } else {
                            vec![envelope]
                        };
                        for event in events {
                            if !is_inbound_for(actor, &event) { continue; }
                            let Some(seq) = event.get("seq").and_then(Value::as_u64) else { continue };
                            let room = event.get("room").and_then(Value::as_str).unwrap_or("").to_string();
                            let from = event.get("from").and_then(Value::as_str).unwrap_or("").to_string();
                            let text = extract_text(&event);
                            let ack = json!({ "v": 1, "type": "message.delivered", "room": room, "from": actor, "ack_of": seq, "payload": {} });
                            if let Err(err) = write.send(Message::Text(ack.to_string())).await {
                                eprintln!("listen: failed to send ack for seq {seq}: {err}");
                            }
                            let hit = InboxHit { seq, room, from, text };
                            if let Err(err) = write_fifo(&fifo_path, &hit) {
                                eprintln!("listen: failed to write inbox pipe: {err:#}");
                            }
                        }
                    }
                    _ => {}
                }
            }
        }
    }
    Ok(())
```

This replaces the previous `while let Some(message) = read.next().await { ... }` loop body from Task 10 — the `for event in events { ... }` block is unchanged, just moved inside the new `tokio::select!`'s `Message::Text` arm.

Update `main.rs`'s `Command::Listen` arm to call the reconnecting `run` instead of `run_once`:

```rust
        Command::Listen(args) => {
            let actor = args.as_actor.unwrap_or_else(|| {
                std::env::var("WORKBENCH_MESH_ACTOR").unwrap_or_else(|_| "session:lead".to_string())
            });
            workbench_mesh::listen::run(args.target, args.home, actor).await
        }
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cargo test -p workbench-mesh 2>&1 | tail -40` and `cargo build -p workbench-mesh --release 2>&1 | tail -30`
Expected: PASS, clean release build.

- [ ] **Step 6: Commit**

```bash
git add crates/workbench-mesh/src/listen.rs crates/workbench-mesh/src/main.rs
git commit -m "feat(mesh): listen connector reconnect/backoff and native ping/pong RTT"
```

---

### Task 12: Frontend — subscribe frame, batch-frame handling, reconnect backoff

**Files:**
- Modify: `crates/workbench-mesh/assets/command-center/live.js`

**Interfaces:**
- Consumes: server's subscribe control frame and `batch` frame shape (Tasks 5, 6).
- Produces: `WB.live.subscribe(rooms)` — called whenever the set of rooms the dashboard cares about changes (initially: `['team', 'repo:<slug>']` plus the operator's own actor id); reconnect now backs off instead of a flat 1500ms.

- [ ] **Step 1: Manual verification baseline**

Before editing, run the existing shell test suite to have a known-good baseline:

Run: `bash test/mesh-command-center.test.sh 2>&1 | tail -40`
Expected: PASS (current baseline, before frontend changes).

- [ ] **Step 2: Add subscribe-on-connect and batch-frame unwrapping**

In `live.js`, modify `connectSocket`:

```javascript
  let reconnectAttempt = 0;
  function backoffMs(attempt) {
    if (attempt === 0) return 250;
    const capped = Math.min(250 * Math.pow(2, Math.min(attempt, 6)), 5000);
    return capped + Math.random() * (capped / 5);
  }

  function connectSocket() {
    if (!token || socket) return;
    const proto = window.location.protocol === 'https:' ? 'wss:' : 'ws:';
    socket = new WebSocket(proto + '//' + window.location.host + '/ws?token=' + encodeURIComponent(token) + '&last_seq=' + sim.seq);
    socket.addEventListener('open', () => {
      reconnectAttempt = 0;
      sendSubscribe();
    });
    socket.addEventListener('message', (e) => {
      lastContact = Date.now();
      let payload = null;
      try { payload = JSON.parse(e.data); } catch (err) { return; }
      if (!payload) return;
      if (payload.type === 'ack' || payload.type === 'pong') { handleControlFrame(payload); return; }
      if (payload.type === 'batch' && Array.isArray(payload.events)) {
        for (const ev of payload.events) { if (ev.seq) ingest(ev, false); }
        recomputeDerived();
        return;
      }
      if (!payload.seq) return;
      ingest(payload, false);
      recomputeDerived();
    });
    socket.addEventListener('close', () => {
      socket = null;
      reconnectAttempt += 1;
      setTimeout(connectSocket, backoffMs(reconnectAttempt));
    });
  }

  let subscribedRooms = [];
  function sendSubscribe() {
    if (!socket || socket.readyState !== WebSocket.OPEN) return;
    socket.send(JSON.stringify({ v: 1, type: 'subscribe', rooms: subscribedRooms, actor: SELF }));
  }
  WB.live = WB.live || {};
  WB.live.subscribe = function (rooms) {
    subscribedRooms = rooms.slice();
    sendSubscribe();
  };
```

`handleControlFrame` is a forward reference to Task 15's ping/pong handling — for this task, stub it minimally so the file stays valid:

```javascript
  function handleControlFrame(payload) {
    // ack: no-op here — optimistic-send reconciliation (Task 14) consumes it
    // pong: RTT measurement (Task 15) consumes it
  }
```

- [ ] **Step 3: Call `WB.live.subscribe` once state is known**

In `loadState`, after `projectHost(data.host)` (so the room slug is known) and before `connectSocket()`:

```javascript
      .then((data) => {
        lastContact = Date.now();
        if (data.host) projectHost(data.host);
        projectDevices(Array.isArray(data.devices) ? data.devices : []);
        const evs = Array.isArray(data.events) ? data.events : [];
        for (const ev of evs) ingest(ev, firstLoad);
        firstLoad = false;
        recomputeDerived();
        if (WB.app) { WB.app.refreshChrome(); WB.app.rerenderSurface(); }
        WB.live.subscribe(defaultRooms());
        connectSocket();
      })
```

Add `defaultRooms`:

```javascript
  function defaultRooms() {
    const rooms = new Set(['team', 'presence']);
    for (const r of WB.ROOMS) { if (!r.output) rooms.add(r.id); }
    rooms.add(SELF);
    return Array.from(rooms);
  }
```

And re-send subscribe on reconnect's `open` event (already wired above via `sendSubscribe()` in the `open` listener — it reuses the last `subscribedRooms`, which is correct: reconnecting should re-subscribe to the same rooms, not recompute from scratch).

- [ ] **Step 4: Manual verification**

Run: `bash test/mesh-command-center.test.sh 2>&1 | tail -40`
Expected: PASS — this shell suite drives the dashboard through curl/websocket checks; if any check depended on receiving broadcast traffic without an explicit subscribe (mirroring the Rust test-suite risk from Task 5, Step 5), update that check to send a subscribe frame first via the test harness's WS client, or to target `WB.CHAT`/`/api/state` (HTTP) assertions instead of a raw WS listen where the check doesn't specifically need to test WS delivery.

Then a manual browser check: start the mesh (`scripts/mesh.sh start --local --as manual-check`), open the dashboard URL, open devtools Network tab, confirm exactly one `subscribe` frame is sent on connect and the dashboard still populates chat/roster as before.

- [ ] **Step 5: Commit**

```bash
git add crates/workbench-mesh/assets/command-center/live.js
git commit -m "feat(mesh): dashboard subscribes to rooms, handles batched frames, backs off on reconnect"
```

---

### Task 13: Frontend — chat pagination (`loadOlder`)

**Files:**
- Modify: `crates/workbench-mesh/assets/command-center/live.js`
- Modify: `crates/workbench-mesh/assets/command-center/bench.js`

**Interfaces:**
- Produces: `WB.api.loadOlder(room, beforeSeq) -> Promise<EventEnvelope[]>`; `bench.js`'s `chatCol()` wires a scroll-near-top listener that calls it and prepends.

- [ ] **Step 1: Add `WB.api.loadOlder`**

In `live.js`, inside the `WB.api` object literal (after `sendChat`):

```javascript
    loadOlder(room, beforeSeq) {
      const params = new URLSearchParams({ room: room, before: String(beforeSeq), limit: '50' });
      return fetch('/api/events?' + params.toString(), { headers: headers(false) })
        .then(requireOk)
        .then((data) => {
          const evs = Array.isArray(data.events) ? data.events : [];
          for (const ev of evs) ingest(ev, true); // quiet — no chat/heartbeat emits, just backfills WB.CHAT
          return evs;
        });
    },
```

`ingest`'s existing `seen` dedup (by `ev.seq`) means replaying older events through the normal path is safe — it will populate `WB.CHAT` (and any other collection) exactly like a fresh event would, just without emitting live UI events (`quiet=true`), which matches how `loadState`'s initial catch-up already works.

- [ ] **Step 2: Track the oldest loaded seq per room and wire scroll-near-top in `bench.js`**

Modify `chatCol()` in `bench.js`. Find the `const scroll = el('div', { class: 'chat-scroll', id: 'chat-scroll' });` line and the `renderChatList(scroll)` call at the end of `chatCol()`; add pagination state and a scroll listener:

```javascript
    let oldestLoadedSeq = null;
    let loadingOlder = false;
    scroll.addEventListener('scroll', () => {
      if (loadingOlder || scroll.scrollTop > 150) return;
      if (oldestLoadedSeq == null) return;
      loadingOlder = true;
      const before = oldestLoadedSeq;
      const prevHeight = scroll.scrollHeight;
      const room = roomFilter === 'all' ? 'team' : roomFilter;
      WB.api.loadOlder(room, before).then((evs) => {
        loadingOlder = false;
        if (!evs.length) return;
        oldestLoadedSeq = Math.min(...evs.map((e) => e.seq));
        renderChatList(scroll);
        scroll.scrollTop = scroll.scrollHeight - prevHeight; // preserve viewport position
      }).catch(() => { loadingOlder = false; });
    });
```

Modify `renderChatList` to track `oldestLoadedSeq` after the initial render and apply the mount cap (mount cap itself lands in Task 14 alongside `content-visibility`; for this task, just seed the cursor):

```javascript
  function renderChatList(scroll) {
    scroll.replaceChildren();
    const matched = WB.CHAT.filter(chatMatches);
    for (const m of matched) scroll.appendChild(msgNode(m));
    scroll.scrollTop = scroll.scrollHeight;
  }
```

Set `oldestLoadedSeq` from the initial page: since `WB.CHAT` entries built from `ingest` don't currently carry `seq` on the projected chat object `m` (`msgNode`/`WB.CHAT.push(m)` in `live.js`'s `ingest` builds `{ room, who, kind, text, ts, to }` — no `seq`), add `seq: ev.seq` to that object literal in `live.js`'s `ingest`:

```javascript
      const m = { room: ev.room, who: displayWho(ev.from), kind: kind, text: text, ts: when, to: ev.to || null, seq: ev.seq };
```

Then in `chatCol()`, after the initial `renderChatList(scroll)` call:

```javascript
    renderChatList(scroll);
    const initialMatched = WB.CHAT.filter(chatMatches);
    oldestLoadedSeq = initialMatched.length ? Math.min(...initialMatched.map((m) => m.seq)) : null;
    renderTypingLine();
```

- [ ] **Step 3: Manual verification**

Since this dashboard has no JS test runner beyond the static `test/mesh-command-center-action-harness.js` module-parsing checks and the shell e2e suite, verify manually:

1. Start the mesh, post 60+ messages via `scripts/mesh.sh message team "msg N"` in a loop (or use `client::bench`'s pattern for volume).
2. Open the dashboard, confirm only the newest ~50 render initially and scroll is at the bottom.
3. Scroll to the top of the chat pane, confirm older messages load in and the viewport doesn't jump.

Run: `bash test/mesh-command-center.test.sh 2>&1 | tail -40`
Expected: PASS — no existing check depends on `WB.CHAT` entries lacking a `seq` field.

- [ ] **Step 4: Commit**

```bash
git add crates/workbench-mesh/assets/command-center/live.js crates/workbench-mesh/assets/command-center/bench.js
git commit -m "feat(mesh): paginate chat history with scroll-up load-older"
```

---

### Task 14: Frontend — mount cap + `content-visibility` + optimistic send + receipts

**Files:**
- Modify: `crates/workbench-mesh/assets/command-center/live.js`
- Modify: `crates/workbench-mesh/assets/command-center/bench.js`
- Modify: `crates/workbench-mesh/assets/command-center/style-surfaces.css`

**Interfaces:**
- Produces: `WB.RECEIPTS: {[seq]: {serverReceivedAt, deliveredBy: Set, seenBy: Set}}`; `msgNode(m)` renders a tick/seen-by indicator; sends render optimistically with a `state: 'sending'` row that reconciles on ack.

- [ ] **Step 1: Add `WB.RECEIPTS` collection and ack ingestion in `live.js`**

Near the other `WB.*` collections at the top of `live.js` (or wherever `WB.FEEDLOG`/`WB.CHAT` etc. are declared — check `data.js` for where the base collections are seeded, since `bench.js` sets `WB.FEEDLOG = {}` itself; follow that pattern):

```javascript
  WB.RECEIPTS = WB.RECEIPTS || {};
```

In `ingest`, add handling for the two ack types (after the "team chat" block):

```javascript
    // delivery/seen receipts
    if ((type === 'message.delivered' || type === 'message.read') && ev.ack_of) {
      const r = WB.RECEIPTS[ev.ack_of] = WB.RECEIPTS[ev.ack_of] || { deliveredBy: new Set(), seenBy: new Set() };
      if (type === 'message.delivered') r.deliveredBy.add(ev.from);
      else r.seenBy.add(ev.from);
      if (!quiet) sim.emit('receipt', ev.ack_of);
    }
```

- [ ] **Step 2: Optimistic send in `WB.api.sendChat`**

Modify `sendChat` to stamp a `serverReceivedAt` the moment the POST resolves (this is the "server-received" tier — the bubble already renders instantly client-side via `bench.js`'s existing `scroll.appendChild(msgNode(m))` right after `sendChat` is called, so this step only needs to record receipt state, not add new optimistic rendering — that already exists per `chatCol()`'s `send` closure):

```javascript
    sendChat(m) {
      pendingSelf.push(m.text);
      const type = m.kind === 'ask' ? 'message.request_status' : m.kind === 'handoff' ? 'task.handoff' : 'message.sent';
      const payload = m.kind === 'handoff' ? { task_id: m.text } : { text: m.text };
      return post(type, m.room === 'team' ? 'repo:workbench' : m.room, payload, m.to || undefined).then((data) => {
        if (data && data.seq) {
          WB.RECEIPTS[data.seq] = WB.RECEIPTS[data.seq] || { deliveredBy: new Set(), seenBy: new Set() };
          WB.RECEIPTS[data.seq].serverReceivedAt = Date.now();
          m.seq = data.seq;
          sim.emit('receipt', data.seq);
        }
        return data;
      });
    },
```

- [ ] **Step 3: Render receipt ticks in `bench.js`'s `msgNode`**

```javascript
  function receiptGlyph(m) {
    if (!m.seq) return null;
    const r = WB.RECEIPTS[m.seq];
    if (!r) return el('span', { class: 'tick tick-sent', title: 'sent', text: '✓' });
    if (r.seenBy && r.seenBy.size) return el('span', { class: 'tick tick-seen', title: 'seen', text: '✓✓' });
    if (r.deliveredBy && r.deliveredBy.size) return el('span', { class: 'tick tick-delivered', title: 'delivered', text: '✓✓' });
    if (r.serverReceivedAt) return el('span', { class: 'tick tick-received', title: 'sent', text: '✓' });
    return null;
  }
  function roomReceiptSummary(m) {
    if (!m.seq || m.to) return null; // room aggregate only applies to non-DM posts
    const r = WB.RECEIPTS[m.seq];
    const seenCount = r && r.seenBy ? r.seenBy.size : 0;
    if (!seenCount) return null;
    const total = WB.AGENTS.filter((a) => WB.eff.heat(a) !== 'dead').length || 1;
    return el('span', { class: 'seen-by', text: 'seen by ' + seenCount + '/' + total });
  }
```

Wire both into `msgNode`'s `me` branch (only the operator's own messages show receipts — mirroring standard chat-app conventions):

```javascript
  function msgNode(m) {
    if (m.kind === 'handoff') {
      return el('div', { class: 'sysline', html: svgIcon('arrow-right', 12) + ' <b>' + WB.ui.esc(m.who) + '</b>&nbsp;handoff — ' + WB.ui.esc(m.text) });
    }
    const me = m.who === 'you (operator)';
    const bubble = el('div', { class: 'bubble' + (m.kind === 'command' ? ' cmd' : '') });
    if (m.kind === 'ask') bubble.appendChild(el('span', { class: 'ask-chip', html: chip('status?', 'amber').outerHTML }));
    bubble.appendChild(document.createTextNode((m.kind === 'command' ? '$ ' : '') + m.text));
    let tag;
    if (m.to) tag = '→ @' + m.to;
    else if (m.room === 'team') tag = '→ team' + (m.via ? ' · via ' + m.via : '');
    else tag = '→ ' + m.room + (me && m.via ? ' · via ' + m.via : '');
    const nameSpan = me ? el('span', { text: m.who }) : leadName(m.who);
    const tsRow = el('div', { class: 'ts' }, [document.createTextNode(clock(m.ts))]);
    if (me) {
      const glyph = receiptGlyph(m);
      if (glyph) tsRow.appendChild(glyph);
      const roomSummary = roomReceiptSummary(m);
      if (roomSummary) tsRow.appendChild(roomSummary);
    }
    return el('div', { class: 'msg' + (me ? ' me' : '') }, [
      el('div', { class: 'who' }, [nameSpan, el('span', { class: 'room-tag', text: ' ' + tag })]),
      bubble,
      tsRow,
    ]);
  }
```

- [ ] **Step 4: Re-render the sending message's row when its receipt updates**

Add a `sim.on('receipt', ...)` listener in `bench.js`, near the existing `WB.sim.on('chat', ...)` listener:

```javascript
  WB.sim.on('receipt', (seq) => {
    const scroll = document.getElementById('chat-scroll');
    if (!scroll) return;
    // Cheap correctness over cleverness: a receipt is rare enough (one per
    // sent message, not per keystroke) that a full re-render of the visible
    // list is fine — no need to hunt for the exact DOM node.
    renderChatList(scroll);
  });
```

- [ ] **Step 5: Add mount cap + `content-visibility` in `renderChatList`**

```javascript
  const CHAT_MOUNT_CAP = 150;
  function renderChatList(scroll) {
    scroll.replaceChildren();
    const matched = WB.CHAT.filter(chatMatches);
    const visible = matched.length > CHAT_MOUNT_CAP ? matched.slice(matched.length - CHAT_MOUNT_CAP) : matched;
    for (const m of visible) {
      const node = msgNode(m);
      node.classList.add('cv-row');
      scroll.appendChild(node);
    }
    scroll.scrollTop = scroll.scrollHeight;
  }
```

Add to `style-surfaces.css`:

```css
.cv-row {
  content-visibility: auto;
  contain-intrinsic-size: 0 56px;
}
.tick {
  margin-left: 6px;
  font-size: 11px;
  letter-spacing: -1px;
  color: var(--ink-3, #8a8f98);
}
.tick-seen, .tick-delivered {
  color: var(--amber-deep, #b8860b);
}
.seen-by {
  margin-left: 8px;
  font-size: 10px;
  color: var(--ink-3, #8a8f98);
}
```

(`contain-intrinsic-size: 0 56px` is an estimate matching a typical single-line chat row's height — if `style-surfaces.css` defines a different real row height via an existing `.msg`/`.bubble` rule, check it with `grep -n "\.msg \|\.bubble" crates/workbench-mesh/assets/command-center/style-surfaces.css` and match that instead of the placeholder `56px`.)

- [ ] **Step 6: Manual verification**

Run: `bash test/mesh-command-center.test.sh 2>&1 | tail -40`
Expected: PASS.

Manually: send a message from the dashboard, confirm the ✓ appears immediately (server-received), then run `workbench-mesh ack --target . --type message.delivered --ack-of <seq> --room repo:workbench --as some-actor` (or exercise the eventual `listen` connector once Task 18 wires it into the harness) and confirm the tick updates to ✓✓ without a page refresh.

- [ ] **Step 7: Commit**

```bash
git add crates/workbench-mesh/assets/command-center/live.js crates/workbench-mesh/assets/command-center/bench.js crates/workbench-mesh/assets/command-center/style-surfaces.css
git commit -m "feat(mesh): receipt ticks, room seen-by summary, DOM mount cap for chat"
```

---

### Task 15: Frontend — app-level ping/pong RTT + presence-freshness from receipts

**Files:**
- Modify: `crates/workbench-mesh/assets/command-center/live.js`
- Modify: `crates/workbench-mesh/assets/command-center/app.js`
- Modify: `crates/workbench-mesh/assets/command-center/bench.js`
- Modify: `crates/workbench-mesh/assets/command-center/style-surfaces.css`

**Interfaces:**
- Produces: `WB.RTT: number|null` (browser↔server, ms); `WB.eff.activity`/`recomputeDerived` treat a fresh receipt as proof-of-life alongside heartbeats.

- [ ] **Step 1: App-level ping/pong in `live.js`**

Extend `handleControlFrame` (stubbed in Task 12) and add a ping ticker:

```javascript
  WB.RTT = null;
  function handleControlFrame(payload) {
    if (payload.type === 'pong' && typeof payload.t === 'number') {
      WB.RTT = Date.now() - payload.t;
      sim.emit('rtt', WB.RTT);
    }
  }
  function sendPing() {
    if (!socket || socket.readyState !== WebSocket.OPEN) return;
    socket.send(JSON.stringify({ v: 1, type: 'ping', t: Date.now() }));
  }
  setInterval(sendPing, 5000);
```

- [ ] **Step 2: Feed receipts into presence freshness**

In `live.js`'s `ingest`, the receipt-handling block added in Task 14 should also bump the acking actor's `lastSeen`, mirroring how a heartbeat does it:

```javascript
    // delivery/seen receipts
    if ((type === 'message.delivered' || type === 'message.read') && ev.ack_of) {
      const r = WB.RECEIPTS[ev.ack_of] = WB.RECEIPTS[ev.ack_of] || { deliveredBy: new Set(), seenBy: new Set() };
      if (type === 'message.delivered') r.deliveredBy.add(ev.from);
      else r.seenBy.add(ev.from);
      const actor = WB.AGENTS.find((a) => a.id === ev.from);
      if (actor) actor.lastSeen = Math.max(actor.lastSeen, when);
      if (!quiet) sim.emit('receipt', ev.ack_of);
    }
```

(This replaces the version added in Task 14, Step 1 — same block, one added line.)

- [ ] **Step 3: Surface RTT in the statusline**

In `app.js`'s `renderStatusline`, add an RTT item to the right-aligned group:

```javascript
    sl.appendChild(el('span', { class: 'sl-right' }, [
      el('span', { class: 'sl-item', html: 'seq <b id="sl-seq">#' + WB.sim.seq + '</b>' }),
      el('span', { class: 'sl-item', id: 'sl-rtt', text: WB.RTT != null ? WB.RTT + 'ms' : '…' }),
      el('span', { class: 'sl-item', text: 'you: operator · token ok' }),
      el('span', { class: 'sl-item sl-dim', text: 'trusted LAN · plaintext HTTP' }),
    ]));
```

Add a live updater alongside the existing `WB.sim.on('tick', ...)`/`WB.sim.on('event', ...)` listeners in `app.js`:

```javascript
  WB.sim.on('rtt', () => {
    const r = document.getElementById('sl-rtt');
    if (r) r.textContent = WB.RTT != null ? WB.RTT + 'ms' : '…';
  });
```

- [ ] **Step 4: Manual verification**

Run: `bash test/mesh-command-center.test.sh 2>&1 | tail -40`
Expected: PASS.

Manually: open the dashboard, confirm the statusline shows an RTT value within ~5s of load and it updates periodically.

- [ ] **Step 5: Commit**

```bash
git add crates/workbench-mesh/assets/command-center/live.js crates/workbench-mesh/assets/command-center/app.js crates/workbench-mesh/assets/command-center/bench.js
git commit -m "feat(mesh): app-level ping/pong RTT display, receipts feed presence freshness"
```

---

### Task 16: Frontend — animated (typewriter) reveal for chat/output chunks

**Files:**
- Modify: `crates/workbench-mesh/assets/command-center/bench.js`
- Modify: `crates/workbench-mesh/assets/command-center/style-surfaces.css`

**Interfaces:**
- Produces: `revealText(node, text, opts)` — progressively fills a text node instead of setting it instantly; used for freshly-arrived chat bubbles and output-feed lines (not for the initial page load/pagination backfill, which should render instantly — only *new* live arrivals get the animation).

- [ ] **Step 1: Add the reveal helper**

Add near the top of `bench.js`, after the `TOOL_ICON` constant:

```javascript
  // Client-side reveal animation only — nothing here changes what data
  // crosses the wire (the tailer still only ever sends finished boundary
  // chunks, never token deltas). This just avoids dumping a whole chunk
  // into the DOM at once, so arrival feels like a continuous stream rather
  // than a bucket dropping in. ~28 chars/frame at 60fps ≈ natural reading pace.
  function revealText(el, text, opts) {
    const o = opts || {};
    const speed = o.charsPerFrame || 3;
    if (o.instant || !text) { el.textContent = text || ''; return; }
    let i = 0;
    el.textContent = '';
    el.classList.add('reveal-cursor');
    function step() {
      i = Math.min(text.length, i + speed);
      el.textContent = text.slice(0, i);
      if (i < text.length) { requestAnimationFrame(step); }
      else { el.classList.remove('reveal-cursor'); }
    }
    requestAnimationFrame(step);
  }
```

- [ ] **Step 2: Apply to freshly-arrived chat bubbles**

Modify the live-arrival chat handler (`WB.sim.on('chat', (m) => { ... })`, not the bulk `renderChatList`/pagination path — those must render instantly):

```javascript
  WB.sim.on('chat', (m) => {
    const scroll = document.getElementById('chat-scroll');
    if (scroll && chatMatches(m)) {
      const pinned = scroll.scrollTop + scroll.clientHeight >= scroll.scrollHeight - 60;
      const node = msgNode(m);
      const isOwn = m.who === 'you (operator)';
      scroll.appendChild(node);
      if (!isOwn) {
        const bubble = node.querySelector('.bubble');
        if (bubble) {
          const full = bubble.textContent;
          revealText(bubble, full);
        }
      }
      if (pinned) scroll.scrollTop = scroll.scrollHeight;
    }
    const feed = document.getElementById('focus-feed');
    if (feed && WB.state.focus) {
      const a = agent(WB.state.focus);
      if (a && a.id === feed.getAttribute('data-agent') && dmMatches(a, m)) {
        const pinned = feed.scrollTop + feed.clientHeight >= feed.scrollHeight - 48;
        feed.appendChild(chatTermLine(m));
        if (pinned) feed.scrollTop = feed.scrollHeight;
      }
    }
  });
```

Own messages (`isOwn`) render instantly — you typed it, animating your own echo back at you would feel wrong. Only messages arriving *from someone else* get the reveal.

- [ ] **Step 3: Apply to the per-agent output feed's tool/message lines**

Modify the `WB.sim.on('output', ...)` handler's focus-feed branch:

```javascript
    const feed = document.getElementById('focus-feed');
    if (feed && feed.getAttribute('data-agent') === id) {
      const pinned = feed.scrollTop + feed.clientHeight >= feed.scrollHeight - 48;
      const node = feedLine({ ts: Date.now(), line: line });
      feed.appendChild(node);
      const textEl = node.querySelector('.fl-text');
      if (textEl) { const full = textEl.textContent; revealText(textEl, full); }
      while (feed.children.length > 80) feed.removeChild(feed.firstChild);
      if (pinned) feed.scrollTop = feed.scrollHeight;
    }
```

- [ ] **Step 4: Add the reveal cursor CSS**

Add to `style-surfaces.css`:

```css
.reveal-cursor::after {
  content: '▍';
  display: inline-block;
  margin-left: 1px;
  animation: reveal-blink 0.9s steps(1) infinite;
  color: var(--amber-deep, #b8860b);
}
@keyframes reveal-blink {
  0%, 49% { opacity: 1; }
  50%, 100% { opacity: 0; }
}
```

- [ ] **Step 5: Manual verification**

Run: `bash test/mesh-command-center.test.sh 2>&1 | tail -40`
Expected: PASS — the shell suite doesn't assert on animation timing, only on final content, and `revealText` converges to the full text regardless of animation (the DOM's final `textContent` after the animation completes equals the source string), so any check reading rendered text after a short settle should be unaffected. If a check reads text immediately after an event without waiting, and starts failing because the reveal hasn't completed yet, add a short wait (`sleep 0.2` or equivalent) in that specific check rather than disabling the animation.

Manually: open the dashboard, have another actor send a chat message, confirm it visibly reveals character-by-character rather than appearing all at once; confirm your own sent messages appear instantly.

- [ ] **Step 6: Commit**

```bash
git add crates/workbench-mesh/assets/command-center/bench.js crates/workbench-mesh/assets/command-center/style-surfaces.css
git commit -m "feat(mesh): animated reveal for incoming chat and output-feed lines"
```

---

### Task 17: Ops — retire the polling inbox wait in favor of the FIFO, update docs

**Files:**
- Modify: `scripts/mesh.sh`
- Modify: `skills/mesh/SKILL.md`
- Test: `test/mesh-command-center.test.sh` (extend)

**Interfaces:**
- Produces: `mesh.sh listen-wait --as ACTOR` — blocks on the actor's FIFO (written by a running `workbench-mesh listen` connector) instead of polling `event list` every 2s; falls back to the existing polling `inbox --wait` behavior if the FIFO doesn't exist (connector not running).

- [ ] **Step 1: Add the `listen-wait` operation to `mesh.sh`**

Add to the usage text (near the existing `inbox` line):

```
  listen-wait --as ACTOR   (blocks on the actor's FIFO, written by `workbench-mesh listen`; falls back to inbox --wait polling if no listen connector is running)
```

Add the operation handler, near the existing `inbox)` case:

```bash
  listen-wait)
    if [ "${#AS_ARGS[@]}" -eq 0 ] && [ -z "${WORKBENCH_MESH_ACTOR:-}" ]; then
      echo "mesh: listen-wait requires --as ACTOR (or export WORKBENCH_MESH_ACTOR)" >&2
      exit 2
    fi
    actor="${AS_ARGS[1]:-$WORKBENCH_MESH_ACTOR}"
    safe_actor="$(printf '%s' "$actor" | tr ':/' '--')"
    fifo="$TARGET/.workbench/mesh/inbox-$safe_actor.fifo"
    if [ -p "$fifo" ]; then
      # Blocking read on a FIFO costs zero CPU while idle and wakes the
      # instant `workbench-mesh listen` writes a line — no polling interval
      # to tune, no latency floor.
      line="$(head -n 1 "$fifo")"
      printf 'mesh inbox for %s:\n%s\n' "$actor" "$line"
      exit 0
    fi
    echo "mesh: no listen connector running for $actor (missing $fifo) — falling back to polling inbox --wait" >&2
    exec "$0" inbox --as "$actor" --wait
    ;;
```

- [ ] **Step 2: Extend the shell e2e test**

Add to `test/mesh-command-center.test.sh` (find the existing tailer e2e section and add a sibling section — follow that section's structure for starting a server, running a CLI subprocess, and asserting on output):

```bash
echo "== listen-wait FIFO fallback =="
# Without a running `workbench-mesh listen` connector, listen-wait must fall
# back to the polling inbox --wait path rather than hanging forever.
timeout 5 bash "$MESH_SH" listen-wait --as fallback-actor > /tmp/listen-wait-fallback.out 2>&1 &
fallback_pid=$!
sleep 1
"$BIN" message --target "$PROJECT_DIR" --to fallback-actor --text "fallback test" --as sender >/dev/null
wait "$fallback_pid" || true
grep -q "fallback test" /tmp/listen-wait-fallback.out || { echo "FAIL: listen-wait fallback did not receive the message"; exit 1; }
echo "listen-wait fallback: PASS"
```

(Adapt variable names — `$MESH_SH`, `$BIN`, `$PROJECT_DIR` — to whatever the existing script already uses; run `grep -n "^MESH_SH=\|^BIN=\|^PROJECT_DIR=" test/mesh-command-center.test.sh` first and match those exact names rather than inventing new ones.)

- [ ] **Step 3: Run the test**

Run: `bash test/mesh-command-center.test.sh 2>&1 | tail -60`
Expected: PASS, including the new `listen-wait fallback` check.

- [ ] **Step 4: Update `skills/mesh/SKILL.md`**

Add a routing line alongside the existing tail/inbox routing entries (find the current inbox routing line with `grep -n "inbox" skills/mesh/SKILL.md` and add adjacent to it):

```
- "wake me instantly when a message arrives, not on a 2s poll" -> if a `workbench-mesh listen --as ACTOR` connector is already running for this actor, use `listen-wait --as ACTOR` as the background push-channel task instead of `inbox --wait`; it blocks on the connector's FIFO with zero polling latency. Falls back to `inbox --wait` automatically if no connector is running.
```

- [ ] **Step 5: Commit**

```bash
git add scripts/mesh.sh skills/mesh/SKILL.md test/mesh-command-center.test.sh
git commit -m "feat(mesh): listen-wait FIFO-based push channel with polling fallback"
```

---

### Task 18: Full-suite verification and release build

**Files:** none (verification only)

- [ ] **Step 1: Run the full Rust test suite**

Run: `cargo test -p workbench-mesh 2>&1 | tail -80`
Expected: PASS, zero failures, zero warnings treated as errors.

- [ ] **Step 2: Run `cargo fmt` and `cargo clippy`**

Run: `cargo fmt -p workbench-mesh -- --check && cargo clippy -p workbench-mesh --all-targets -- -D warnings 2>&1 | tail -80`
Expected: PASS. Fix any formatting/lint findings — the `recv_any`/`select_all` code from Task 5 in particular is a likely clippy target (e.g. `needless_collect` on the `Vec` of futures); address whatever it flags without changing behavior.

- [ ] **Step 3: Build the release binary and re-run the shell e2e suite against it**

Run: `cargo build -p workbench-mesh --release 2>&1 | tail -30 && bash test/mesh-command-center.test.sh 2>&1 | tail -80`
Expected: PASS — this is the binary `scripts/mesh.sh` actually shells out to (`bin/workbench-mesh` prefers `target/release`), so a green run here is what matters for real usage, not just `cargo test`'s debug build.

- [ ] **Step 4: Run the full existing test/all.sh suite**

Run: `bash test/all.sh 2>&1 | tail -100`
Expected: PASS — confirms this work didn't regress the channel/wizard/tailer suites built in earlier sessions.

- [ ] **Step 5: Update `CHANGELOG.md`**

Add an `## [Unreleased]` (or the next version section, matching whatever convention `CHANGELOG.md` currently uses at its top — check with `head -20 CHANGELOG.md` first) entry summarizing: WS subscription filtering, receipt chain (delivered/seen), `workbench-mesh listen` connector, chat pagination, optimistic send, RTT display, animated reveal. Follow the existing changelog's bullet style exactly rather than inventing a new format.

- [ ] **Step 6: Commit**

```bash
git add CHANGELOG.md
git commit -m "docs: changelog entry for the mesh real-time protocol work"
```
