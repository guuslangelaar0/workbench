# Workbench Mesh Command Center Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build Workbench Mesh as a packaged Rust control-plane binary with local/LAN realtime coordination, authenticated invites, Claude-facing commands/hooks, command center UI, statusline presence, and outcome-level plugin tests.

**Architecture:** A Rust binary named `workbench-mesh` owns the daemon, API, WebSocket protocol, event store, auth, command center UI, and client CLI subcommands. Existing Bash scripts stay as thin workbench wrappers that find the Rust binary through `${CLAUDE_PLUGIN_ROOT}` and keep the slash-command/hook surfaces consistent with the rest of the plugin. Repo files remain the durable work truth; mesh files under `.workbench/mesh/` and `~/.workbench/mesh/` hold live coordination state and secrets.

**Tech Stack:** Rust workspace, `tokio`, `axum`, `serde`, `serde_json`, `clap`, `uuid`, `time`, `hmac`, `sha2`, `rand`, `base64`, shell tests, Rust integration tests, Claude Code plugin live e2e tests.

## Global Constraints

- Runtime service must be Rust, not Python, Node, or a shell daemon.
- The installed plugin must invoke a packaged binary through `bin/`; Claude Code plugin docs add plugin `bin/` executables to Bash `PATH`.
- Bash scripts may wrap the binary but must not own mesh runtime behavior.
- Support macOS and Linux first: `aarch64-apple-darwin`, `x86_64-apple-darwin`, `aarch64-unknown-linux-gnu`, `x86_64-unknown-linux-gnu`.
- Auth is always required, including same-user localhost; same-user localhost uses OS-protected credentials outside git.
- Public internet exposure is out of scope for this plan.
- Realtime protocol is versioned JSON over WebSocket; gRPC/protobuf and WebRTC are deferred.
- No `jq` dependency in user-facing shell scripts.
- Use TDD: each task starts with failing tests, then minimal implementation, then focused verification.
- Outcome-level plugin verification is required: the test suite must prove the slash-command/plugin surface actually produces the user-visible mesh outcomes, not only isolated library behavior.
- Do not bump plugin version during feature implementation; use `[Unreleased]` changelog only.

---

## File Structure

Create:

- `Cargo.toml` - Rust workspace root.
- `crates/workbench-mesh/Cargo.toml` - daemon/client crate.
- `crates/workbench-mesh/src/main.rs` - CLI entry point.
- `crates/workbench-mesh/src/protocol.rs` - event envelope, event kinds, validation, state model.
- `crates/workbench-mesh/src/store.rs` - append-only JSONL event/audit store and state projection.
- `crates/workbench-mesh/src/auth.rs` - device root key, project credentials, invites, token validation.
- `crates/workbench-mesh/src/net.rs` - host/IP/interface detection and bind address selection.
- `crates/workbench-mesh/src/server.rs` - HTTP API, WebSocket, static UI serving.
- `crates/workbench-mesh/src/client.rs` - CLI client calls to the daemon.
- `crates/workbench-mesh/src/statusline.rs` - cached snapshot rendering.
- `crates/workbench-mesh/assets/index.html` - command center shell.
- `crates/workbench-mesh/assets/app.js` - command center client logic.
- `crates/workbench-mesh/assets/style.css` - dense command-center styling.
- `bin/workbench-mesh` - POSIX launcher that selects the packaged Rust binary.
- `scripts/mesh.sh` - existing-pattern wrapper used by commands/hooks/tests.
- `commands/mesh.md` - Claude slash command surface.
- `skills/mesh/SKILL.md` - Claude routing rules for natural mesh intents.
- `hooks/bin/mesh-context.sh` - inject mesh presence into prompt/session context.
- `hooks/bin/mesh-statusline.sh` - Claude Code statusline command.
- `test/mesh-protocol.test.sh` - shell-facing protocol/store tests.
- `test/mesh-auth.test.sh` - local credential and invite tests.
- `test/mesh-service.test.sh` - daemon API/WebSocket outcome tests.
- `test/mesh-ops.test.sh` - room/message/actor/statusline snapshot operation tests.
- `test/mesh-command-center.test.sh` - command center/API interaction tests.
- `test/mesh-hooks.test.sh` - hook context and terminal statusline tests.
- `test/mesh-plugin-outcome.test.sh` - offline plugin-surface outcome tests.
- `test/mesh-packaging.test.sh` - binary launcher/package layout tests.

Modify:

- `hooks/hooks.json` - add mesh prompt/session context hook.
- `test/all.sh` - include mesh suites.
- `test/e2e/run.sh` - add gated live-plugin mesh scenarios.
- `.github/workflows/ci.yml` - install Rust, cache Cargo, run Rust tests and package checks.
- `.gitignore` - ignore Rust build artifacts and generated local mesh runtime state.
- `README.md`, `docs/commands.md`, `docs/concepts.md`, `docs/configuration.md`, `CHANGELOG.md`.
- `scripts/validate-plugin.sh` - validate required Rust binary launcher/package surfaces.

---

### Task 1: Rust Workspace And Protocol Core

**Files:**
- Create: `Cargo.toml`
- Create: `crates/workbench-mesh/Cargo.toml`
- Create: `crates/workbench-mesh/src/main.rs`
- Create: `crates/workbench-mesh/src/protocol.rs`
- Create: `crates/workbench-mesh/src/store.rs`
- Create: `test/mesh-protocol.test.sh`
- Modify: `.gitignore`

**Interfaces:**
- Produces: `workbench-mesh event append --target DIR --type TYPE --room ROOM --from ACTOR --payload-json JSON`
- Produces: `workbench-mesh event list --target DIR [--since SEQ]`
- Produces: `workbench_mesh::protocol::{EventEnvelope, ALLOWED_EVENT_TYPES, validate_event_type}`
- Produces: `.workbench/mesh/events.jsonl` and `.workbench/mesh/audit.jsonl`

- [ ] **Step 1: Write failing shell protocol test**

Create `test/mesh-protocol.test.sh`:

```bash
#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail=0
chk() { if eval "$2"; then echo "ok: $1"; else echo "FAIL: $1" >&2; fail=1; fi; }

bash "$HERE/scripts/init.sh" --name "MeshProto" --mission "Test." --target "$TMP" --profile full --level crew >/dev/null 2>&1
BIN="$HERE/target/debug/workbench-mesh"

"$BIN" event append --target "$TMP" --type presence.join --room repo:meshproto --from session:lead \
  --payload-json '{"role":"lead","purpose":"checkout"}' > "$TMP/append.out"

chk "event log created" "[ -f '$TMP/.workbench/mesh/events.jsonl' ]"
chk "append reports seq 1" "grep -q 'seq=1' '$TMP/append.out'"
chk "event envelope has version" "grep -q '\"v\":1' '$TMP/.workbench/mesh/events.jsonl'"
chk "event type stored" "grep -q '\"type\":\"presence.join\"' '$TMP/.workbench/mesh/events.jsonl'"

"$BIN" event append --target "$TMP" --type message.sent --room repo:meshproto --from session:lead \
  --payload-json '{"text":"status?"}' >/dev/null

LIST="$("$BIN" event list --target "$TMP" --since 1)"
chk "list since seq 1 shows second event" "printf '%s' \"\$LIST\" | grep -q 'message.sent'"
chk "list since seq 1 hides first event" "! printf '%s' \"\$LIST\" | grep -q 'presence.join'"

BAD_RC=0
"$BIN" event append --target "$TMP" --type not.valid --room repo:meshproto --from session:lead \
  --payload-json '{}' >/tmp/mesh.bad.$$ 2>&1 || BAD_RC=$?
chk "invalid event type is rejected" "[ '$BAD_RC' -ne 0 ] && grep -qi 'invalid event type' /tmp/mesh.bad.$$"
rm -f /tmp/mesh.bad.$$

[ "$fail" = 0 ] && echo "PASS: mesh-protocol" || { echo "mesh-protocol test failed"; exit 1; }
```

- [ ] **Step 2: Run test and verify it fails before the binary exists**

Run:

```bash
bash test/mesh-protocol.test.sh
```

Expected: fail with `target/debug/workbench-mesh: No such file or directory`.

- [ ] **Step 3: Add Rust workspace and crate metadata**

Create root `Cargo.toml`:

```toml
[workspace]
members = ["crates/workbench-mesh"]
resolver = "2"

[workspace.package]
edition = "2021"
license = "MIT"
repository = "https://github.com/guuslangelaar0/workbench"
```

Create `crates/workbench-mesh/Cargo.toml`:

```toml
[package]
name = "workbench-mesh"
version = "0.1.0"
edition.workspace = true
license.workspace = true
repository.workspace = true

[dependencies]
anyhow = "1"
base64 = "0.22"
clap = { version = "4", features = ["derive"] }
hmac = "0.12"
rand = "0.8"
serde = { version = "1", features = ["derive"] }
serde_json = "1"
sha2 = "0.10"
time = { version = "0.3", features = ["formatting", "parsing", "serde"] }
tokio = { version = "1", features = ["macros", "rt-multi-thread", "signal", "time", "fs", "net", "sync"] }
uuid = { version = "1", features = ["v7", "serde"] }

[dev-dependencies]
tempfile = "3"
```

Update `.gitignore`:

```text
/target/
/.workbench/mesh/
```

- [ ] **Step 4: Implement protocol and store**

Implement these exact public shapes in `protocol.rs`:

```rust
use serde::{Deserialize, Serialize};
use serde_json::Value;

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
}

pub const ALLOWED_EVENT_TYPES: &[&str] = &[
    "presence.join", "presence.heartbeat", "presence.stale", "device.capabilities",
    "room.created", "room.member_added",
    "message.sent", "message.delivered", "message.read", "message.reply", "message.mention",
    "message.request_status", "message.status_response", "message.help_request",
    "message.help_offer", "message.conflict_warning",
    "lead.purpose_set", "lead.closed", "lead.adopted",
    "actor.spawned", "actor.heartbeat", "actor.status", "actor.output", "actor.done",
    "actor.failed", "actor.stale", "actor.cancelled",
    "task.claim", "task.handoff", "task.handoff.accepted", "task.status", "task.reassigned",
    "job.queued", "job.started", "job.output", "job.done", "job.failed", "job.cancelled",
    "decision.request", "decision.answer",
    "invite.created", "invite.accepted", "invite.revoked",
];

pub fn validate_event_type(event_type: &str) -> anyhow::Result<()> {
    if ALLOWED_EVENT_TYPES.contains(&event_type) {
        Ok(())
    } else {
        anyhow::bail!("invalid event type: {event_type}")
    }
}
```

Implement `store.rs` with:

```rust
pub struct MeshStore {
    root: std::path::PathBuf,
}

impl MeshStore {
    pub fn open(project_root: impl Into<std::path::PathBuf>) -> anyhow::Result<Self>;
    pub fn append_event(&self, event_type: &str, room: &str, from: &str, to: Option<&str>, payload: serde_json::Value) -> anyhow::Result<EventEnvelope>;
    pub fn list_events_since(&self, since: u64) -> anyhow::Result<Vec<EventEnvelope>>;
    pub fn append_audit(&self, action: &str, actor: &str, payload: serde_json::Value) -> anyhow::Result<EventEnvelope>;
}
```

- [ ] **Step 5: Implement CLI event subcommands**

Implement `main.rs` with `clap` subcommands:

```text
workbench-mesh event append --target DIR --type TYPE --room ROOM --from ACTOR [--to ACTOR] --payload-json JSON
workbench-mesh event list --target DIR [--since SEQ]
```

Output for append must include:

```text
event: appended seq=<n> id=<id> type=<type>
```

- [ ] **Step 6: Run focused checks**

Run:

```bash
cargo test -p workbench-mesh
cargo build -p workbench-mesh
bash test/mesh-protocol.test.sh
```

Expected: all pass.

- [ ] **Step 7: Commit**

```bash
git add Cargo.toml crates/workbench-mesh test/mesh-protocol.test.sh .gitignore
git commit -m "feat(mesh): add Rust protocol store"
```

---

### Task 2: Auth, Local Credentials, And Invites

**Files:**
- Create: `crates/workbench-mesh/src/auth.rs`
- Modify: `crates/workbench-mesh/src/main.rs`
- Modify: `crates/workbench-mesh/src/store.rs`
- Create: `test/mesh-auth.test.sh`

**Interfaces:**
- Produces: `workbench-mesh auth bootstrap --target DIR --home DIR`
- Produces: `workbench-mesh invite create --target DIR --home DIR --role ROLE [--ttl-seconds N] [--max-uses N]`
- Produces: `workbench-mesh invite accept --target DIR --home DIR --token TOKEN --device NAME`
- Produces: `workbench-mesh auth check --target DIR --home DIR --token TOKEN`
- Produces: secret files under `$WORKBENCH_HOME/mesh/devices/` and `$WORKBENCH_HOME/mesh/projects/`

- [ ] **Step 1: Write failing auth test**

Create `test/mesh-auth.test.sh`:

```bash
#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
HOME_TMP="$(mktemp -d)"
trap 'rm -rf "$TMP" "$HOME_TMP"' EXIT
fail=0
chk() { if eval "$2"; then echo "ok: $1"; else echo "FAIL: $1" >&2; fail=1; fi; }

bash "$HERE/scripts/init.sh" --name "MeshAuth" --mission "Test." --target "$TMP" --profile full --level crew >/dev/null 2>&1
BIN="$HERE/target/debug/workbench-mesh"

"$BIN" auth bootstrap --target "$TMP" --home "$HOME_TMP" > "$TMP/bootstrap.out"
chk "bootstrap prints authenticated local user" "grep -q 'local credential ready' '$TMP/bootstrap.out'"
chk "device key stored outside repo" "find '$HOME_TMP/mesh/devices' -type f -name '*.key' | grep -q ."
chk "project credential stored outside repo" "find '$HOME_TMP/mesh/projects' -type f -name '*.cred' | grep -q ."
chk "repo contains no secret key files" "! find '$TMP/.workbench' -name '*.key' -o -name '*.cred' | grep -q ."

MODE="$(find "$HOME_TMP/mesh/devices" -type f -name '*.key' -print -quit | xargs stat -c '%a' 2>/dev/null || true)"
if [ -n "$MODE" ]; then
  chk "device key mode is 600 on linux" "[ '$MODE' = 600 ]"
else
  echo "ok: device key mode skipped on non-GNU stat"
fi

INVITE="$("$BIN" invite create --target "$TMP" --home "$HOME_TMP" --role worker --ttl-seconds 900 --max-uses 1)"
TOKEN="$(printf '%s\n' "$INVITE" | sed -n 's/^token: //p' | head -1)"
chk "invite prints token" "[ -n '$TOKEN' ]"
chk "invite prints worker role" "printf '%s' \"\$INVITE\" | grep -q 'role: worker'"
chk "invite audit written" "grep -q 'invite.created' '$TMP/.workbench/mesh/audit.jsonl'"

"$BIN" invite accept --target "$TMP" --home "$HOME_TMP" --token "$TOKEN" --device macbook > "$TMP/accept.out"
chk "invite accept prints connected device" "grep -q 'device macbook connected' '$TMP/accept.out'"
chk "accept audit written" "grep -q 'invite.accepted' '$TMP/.workbench/mesh/audit.jsonl'"

RC=0
"$BIN" invite accept --target "$TMP" --home "$HOME_TMP" --token "$TOKEN" --device second >/tmp/mesh.invite.$$ 2>&1 || RC=$?
chk "single-use invite cannot be reused" "[ '$RC' -ne 0 ] && grep -qi 'invite exhausted' /tmp/mesh.invite.$$"
rm -f /tmp/mesh.invite.$$

[ "$fail" = 0 ] && echo "PASS: mesh-auth" || { echo "mesh-auth test failed"; exit 1; }
```

- [ ] **Step 2: Run test and verify it fails before auth exists**

Run:

```bash
cargo build -p workbench-mesh
bash test/mesh-auth.test.sh
```

Expected: fail because `auth` and `invite` subcommands are missing.

- [ ] **Step 3: Implement `auth.rs`**

Implement:

```rust
pub struct AuthPaths {
    pub home: std::path::PathBuf,
    pub device_dir: std::path::PathBuf,
    pub project_dir: std::path::PathBuf,
}

pub struct Invite {
    pub token: String,
    pub role: String,
    pub expires_at: String,
    pub max_uses: u32,
    pub uses: u32,
}

pub fn paths(home: Option<std::path::PathBuf>) -> anyhow::Result<AuthPaths>;
pub fn bootstrap(project_root: &std::path::Path, home: Option<std::path::PathBuf>) -> anyhow::Result<String>;
pub fn create_invite(project_root: &std::path::Path, home: Option<std::path::PathBuf>, role: &str, ttl_seconds: u64, max_uses: u32) -> anyhow::Result<Invite>;
pub fn accept_invite(project_root: &std::path::Path, home: Option<std::path::PathBuf>, token: &str, device: &str) -> anyhow::Result<String>;
pub fn validate_role(role: &str) -> anyhow::Result<()>;
```

Implementation requirements:

- Generate 32 random bytes for keys and encode URL-safe base64.
- Store device keys with Unix mode `0600` using `std::os::unix::fs::OpenOptionsExt` on Unix.
- Use `$WORKBENCH_HOME` when provided by env or `--home`; otherwise use `~/.workbench`.
- Never write `*.key`, `*.cred`, or raw tokens into `.claude/` or committed templates.
- Append audit events for invite create, accept, exhausted, expired, and revoke.

- [ ] **Step 4: Add CLI subcommands and output**

Required output shapes:

```text
local credential ready
home: <path>
project: <project-id>
```

```text
token: wb_invite_<opaque>
role: worker
expires: <iso timestamp>
max_uses: 1
```

```text
device macbook connected
role: worker
```

- [ ] **Step 5: Run focused checks**

Run:

```bash
cargo test -p workbench-mesh
bash test/mesh-auth.test.sh
```

Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add crates/workbench-mesh/src/auth.rs crates/workbench-mesh/src/main.rs crates/workbench-mesh/src/store.rs test/mesh-auth.test.sh
git commit -m "feat(mesh): add authenticated local credentials and invites"
```

---

### Task 3: Rust Mesh Service, HTTP API, WebSocket, And Performance Smoke

**Files:**
- Create: `crates/workbench-mesh/src/net.rs`
- Create: `crates/workbench-mesh/src/server.rs`
- Create: `crates/workbench-mesh/src/client.rs`
- Modify: `crates/workbench-mesh/Cargo.toml`
- Modify: `crates/workbench-mesh/src/main.rs`
- Create: `test/mesh-service.test.sh`

**Interfaces:**
- Produces: `workbench-mesh serve --target DIR --home DIR --bind local|lan --port PORT --pid-file PATH`
- Produces: `workbench-mesh status --target DIR --home DIR`
- Produces: `workbench-mesh who --target DIR --home DIR`
- Produces: `workbench-mesh bench --target DIR --home DIR --messages N`
- Produces HTTP:
  - `GET /health`
  - `GET /api/state`
  - `GET /api/events?since=N`
  - `POST /api/events`
  - `POST /api/invites`
  - `GET /ws?token=TOKEN&last_seq=N`

- [ ] **Step 1: Add server dependencies**

Add to `crates/workbench-mesh/Cargo.toml`:

```toml
axum = { version = "0.7", features = ["ws"] }
futures-util = "0.3"
reqwest = { version = "0.12", default-features = false, features = ["json", "rustls-tls"] }
tower-http = { version = "0.6", features = ["cors"] }
```

- [ ] **Step 2: Write failing service test**

Create `test/mesh-service.test.sh`:

```bash
#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
HOME_TMP="$(mktemp -d)"
LOG="$TMP/mesh.log"
PIDF="$TMP/mesh.pid"
trap 'kill "$(cat "$PIDF" 2>/dev/null)" >/dev/null 2>&1 || true; rm -rf "$TMP" "$HOME_TMP"' EXIT
fail=0
chk() { if eval "$2"; then echo "ok: $1"; else echo "FAIL: $1" >&2; fail=1; fi; }

bash "$HERE/scripts/init.sh" --name "MeshSvc" --mission "Test." --target "$TMP" --profile full --level crew >/dev/null 2>&1
BIN="$HERE/target/debug/workbench-mesh"
"$BIN" auth bootstrap --target "$TMP" --home "$HOME_TMP" >/dev/null

"$BIN" serve --target "$TMP" --home "$HOME_TMP" --bind local --port 0 --pid-file "$PIDF" > "$LOG" 2>&1 &
for _ in $(seq 1 50); do
  [ -f "$TMP/.workbench/mesh/server.json" ] && break
  sleep 0.1
done

PORT="$(sed -n 's/.*"port":\([0-9][0-9]*\).*/\1/p' "$TMP/.workbench/mesh/server.json" | head -1)"
TOKEN="$(sed -n 's/.*"local_token":"\([^"]*\)".*/\1/p' "$TMP/.workbench/mesh/server.json" | head -1)"
chk "server wrote port" "[ -n '$PORT' ]"
chk "server wrote local token" "[ -n '$TOKEN' ]"

HEALTH="$(curl -fsS "http://127.0.0.1:$PORT/health")"
chk "health returns ok" "printf '%s' \"\$HEALTH\" | grep -q '\"ok\":true'"

POST="$(curl -fsS -X POST "http://127.0.0.1:$PORT/api/events" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"type":"presence.join","room":"repo:meshsvc","from":"session:lead","payload":{"role":"lead"}}')"
chk "post event returns seq" "printf '%s' \"\$POST\" | grep -q '\"seq\":1'"

STATE="$(curl -fsS "http://127.0.0.1:$PORT/api/state" -H "Authorization: Bearer $TOKEN")"
chk "state includes active session" "printf '%s' \"\$STATE\" | grep -q 'session:lead'"

WHO="$("$BIN" who --target "$TMP" --home "$HOME_TMP")"
chk "who uses daemon state" "printf '%s' \"\$WHO\" | grep -q 'session:lead'"

BENCH="$("$BIN" bench --target "$TMP" --home "$HOME_TMP" --messages 100)"
chk "bench reports p95 latency" "printf '%s' \"\$BENCH\" | grep -q 'p95_ms='"

UNAUTH_RC=0
curl -fsS "http://127.0.0.1:$PORT/api/state" >/tmp/mesh.unauth.$$ 2>&1 || UNAUTH_RC=$?
chk "api rejects missing auth" "[ '$UNAUTH_RC' -ne 0 ]"
rm -f /tmp/mesh.unauth.$$

[ "$fail" = 0 ] && echo "PASS: mesh-service" || { echo "mesh-service test failed"; exit 1; }
```

- [ ] **Step 3: Run test and verify it fails before service exists**

Run:

```bash
cargo build -p workbench-mesh
bash test/mesh-service.test.sh
```

Expected: fail because `serve` is missing.

- [ ] **Step 4: Implement network detection**

Implement `net.rs`:

```rust
pub struct BindInfo {
    pub bind_addr: std::net::SocketAddr,
    pub mode: String,
    pub hostname: String,
    pub mdns_name: String,
    pub lan_ips: Vec<String>,
}

pub fn detect_bind(mode: &str, port: u16) -> anyhow::Result<BindInfo>;
```

Requirements:

- `local` binds `127.0.0.1:<port>`.
- `lan` binds `0.0.0.0:<port>` for the first implementation.
- Hostname comes from `hostname` command fallback or env `HOSTNAME`.
- mDNS name is `<hostname>.local` after replacing spaces with hyphens.
- LAN IP collection may use UDP socket interface detection for default outbound IP and should never include `127.0.0.1`.

- [ ] **Step 5: Implement HTTP API and daemon metadata**

Implement `server.rs`:

```rust
pub async fn serve(opts: ServeOptions) -> anyhow::Result<()>;

pub struct ServeOptions {
    pub project_root: std::path::PathBuf,
    pub home: Option<std::path::PathBuf>,
    pub bind: String,
    pub port: u16,
    pub pid_file: Option<std::path::PathBuf>,
}
```

Write `.workbench/mesh/server.json` after binding:

```json
{
  "mode": "local",
  "host": "127.0.0.1",
  "port": 47321,
  "hostname": "guus-macbook",
  "mdns": "guus-macbook.local",
  "lan_ips": ["192.168.1.42"],
  "local_token": "..."
}
```

The local token in `server.json` is a local project bearer token. The file must be mode `0600` on Unix.

- [ ] **Step 6: Implement WebSocket broadcast and replay**

`GET /ws?token=TOKEN&last_seq=N` must:

- authenticate the token
- send events with `seq > last_seq` immediately after connect
- broadcast new events to all connected clients
- accept client JSON events and append them through `MeshStore`
- respond with ACK messages for appended events:

```json
{"type":"ack","id":"evt_...","seq":12}
```

- [ ] **Step 7: Implement client commands**

`client.rs` should read `.workbench/mesh/server.json`, attach the bearer token, and implement:

```text
status
who
bench
```

`status` output must include bind mode, URL, connected actor count, and event count.

- [ ] **Step 8: Run focused checks**

Run:

```bash
cargo test -p workbench-mesh
cargo build -p workbench-mesh
bash test/mesh-service.test.sh
```

Expected: all pass.

- [ ] **Step 9: Commit**

```bash
git add crates/workbench-mesh test/mesh-service.test.sh
git commit -m "feat(mesh): add Rust realtime service"
```

---

### Task 4: CLI Operations For Rooms, Messages, Actors, Tasks, And Statusline Snapshot

**Files:**
- Modify: `crates/workbench-mesh/src/client.rs`
- Modify: `crates/workbench-mesh/src/protocol.rs`
- Modify: `crates/workbench-mesh/src/statusline.rs`
- Modify: `crates/workbench-mesh/src/main.rs`
- Create: `test/mesh-ops.test.sh`

**Interfaces:**
- Produces:
  - `workbench-mesh room create --name NAME`
  - `workbench-mesh message --to ROOM_OR_ACTOR --text TEXT`
  - `workbench-mesh ask --to ACTOR --question TEXT`
  - `workbench-mesh handoff --task-id ID --to ACTOR`
  - `workbench-mesh availability STATE [--reason TEXT]`
  - `workbench-mesh doing TEXT`
  - `workbench-mesh watch ACTOR`
  - `workbench-mesh actor spawn --kind KIND --parent ID --purpose TEXT [--task-id ID]`
  - `workbench-mesh snapshot statusline`
- Produces: `~/.workbench/mesh/statusline/<project-id>.json`

- [ ] **Step 1: Write failing operations test**

Create `test/mesh-ops.test.sh` using the same server setup pattern as `test/mesh-service.test.sh`. Include these assertions:

```bash
"$BIN" room create --target "$TMP" --home "$HOME_TMP" --name lead:checkout
"$BIN" message --target "$TMP" --home "$HOME_TMP" --to lead:checkout --text "what are you touching?"
"$BIN" ask --target "$TMP" --home "$HOME_TMP" --to session:worker --question "status?"
"$BIN" actor spawn --target "$TMP" --home "$HOME_TMP" --kind verifier --parent session:lead --purpose "verify task 0042" --task-id 0042
"$BIN" availability --target "$TMP" --home "$HOME_TMP" busy --reason "running checkout tests"
"$BIN" doing --target "$TMP" --home "$HOME_TMP" "running checkout retry tests"
"$BIN" watch --target "$TMP" --home "$HOME_TMP" session:worker
"$BIN" snapshot statusline --target "$TMP" --home "$HOME_TMP"
```

Assert:

```bash
grep -q 'room.created' "$TMP/.workbench/mesh/events.jsonl"
grep -q 'message.sent' "$TMP/.workbench/mesh/events.jsonl"
grep -q 'message.request_status' "$TMP/.workbench/mesh/events.jsonl"
grep -q 'actor.spawned' "$TMP/.workbench/mesh/events.jsonl"
grep -q 'presence.heartbeat' "$TMP/.workbench/mesh/events.jsonl"
find "$HOME_TMP/mesh/statusline" -type f -name '*.json' | grep -q .
```

- [ ] **Step 2: Run and verify failure**

Run:

```bash
bash test/mesh-ops.test.sh
```

Expected: fail because operation subcommands are missing.

- [ ] **Step 3: Implement operation subcommands**

Map commands to event types:

```text
room create       -> room.created
message           -> message.sent
ask               -> message.request_status
handoff           -> task.handoff
availability      -> presence.heartbeat payload.availability
doing             -> actor.status payload.current_step
watch             -> message.sent payload.intent=watch
actor spawn       -> actor.spawned
snapshot          -> local cache write, no network call required when server state is available in events.jsonl
```

- [ ] **Step 4: Implement statusline snapshot projection**

`statusline.rs` must project:

```rust
pub struct StatuslineSnapshot {
    pub project: String,
    pub current_actor: String,
    pub purpose: Option<String>,
    pub availability: String,
    pub doing: Option<String>,
    pub active_count: usize,
    pub stale_count: usize,
    pub watched: Vec<String>,
    pub unread_mentions: usize,
}
```

Render compact text:

```text
workbench | checkout lead | busy: running checkout retry tests | team 3 active, 1 stale
```

- [ ] **Step 5: Run focused checks**

Run:

```bash
cargo test -p workbench-mesh
bash test/mesh-ops.test.sh
```

Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add crates/workbench-mesh test/mesh-ops.test.sh
git commit -m "feat(mesh): add team operations and status snapshots"
```

---

### Task 5: Packaged Binary Launcher And Plugin Command Surface

**Files:**
- Create: `bin/workbench-mesh`
- Create: `scripts/mesh.sh`
- Create: `commands/mesh.md`
- Create: `skills/mesh/SKILL.md`
- Create: `test/mesh-packaging.test.sh`
- Modify: `test/command.test.sh`
- Modify: `test/skills.test.sh`
- Modify: `scripts/validate-plugin.sh`

**Interfaces:**
- Produces: `bin/workbench-mesh` executable on plugin PATH.
- Produces: `scripts/mesh.sh` wrapper with all slash-command operations.
- Produces: `/workbench:mesh`.

- [ ] **Step 1: Write failing packaging test**

Create `test/mesh-packaging.test.sh`:

```bash
#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail=0
chk() { if eval "$2"; then echo "ok: $1"; else echo "FAIL: $1" >&2; fail=1; fi; }

chk "bin launcher exists" "[ -f '$HERE/bin/workbench-mesh' ]"
chk "bin launcher executable" "[ -x '$HERE/bin/workbench-mesh' ]"
chk "scripts mesh wrapper exists" "[ -f '$HERE/scripts/mesh.sh' ]"
chk "mesh wrapper syntactically valid" "bash -n '$HERE/scripts/mesh.sh'"
chk "mesh command exists" "[ -f '$HERE/commands/mesh.md' ]"
chk "mesh command calls mesh.sh" "grep -q 'scripts/mesh.sh' '$HERE/commands/mesh.md'"
chk "mesh skill exists" "[ -f '$HERE/skills/mesh/SKILL.md' ]"
chk "validate plugin knows bin surface" "bash '$HERE/scripts/validate-plugin.sh' '$HERE' | grep -q 'publishable'"

[ "$fail" = 0 ] && echo "PASS: mesh-packaging" || { echo "mesh-packaging test failed"; exit 1; }
```

- [ ] **Step 2: Run and verify failure**

Run:

```bash
bash test/mesh-packaging.test.sh
```

Expected: fail because `bin/workbench-mesh` and command surface are missing.

- [ ] **Step 3: Add binary launcher**

Create `bin/workbench-mesh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
os="$(uname -s)"
arch="$(uname -m)"
case "$os:$arch" in
  Darwin:arm64)  target="aarch64-apple-darwin" ;;
  Darwin:x86_64) target="x86_64-apple-darwin" ;;
  Linux:aarch64|Linux:arm64) target="aarch64-unknown-linux-gnu" ;;
  Linux:x86_64) target="x86_64-unknown-linux-gnu" ;;
  *) echo "workbench-mesh: unsupported platform $os/$arch" >&2; exit 70 ;;
esac

bin="$ROOT/bin/workbench-mesh.d/$target/workbench-mesh"
if [ -x "$bin" ]; then
  exec "$bin" "$@"
fi

if [ -x "$ROOT/target/release/workbench-mesh" ]; then
  exec "$ROOT/target/release/workbench-mesh" "$@"
fi
if [ -x "$ROOT/target/debug/workbench-mesh" ]; then
  exec "$ROOT/target/debug/workbench-mesh" "$@"
fi

echo "workbench-mesh: packaged binary missing for $target" >&2
echo "run: cargo build -p workbench-mesh --release" >&2
exit 69
```

Set executable:

```bash
chmod +x bin/workbench-mesh
```

- [ ] **Step 4: Add `scripts/mesh.sh` wrapper**

Wrapper requirements:

- Resolve `${CLAUDE_PLUGIN_ROOT:-repo root}`.
- Prefer `$CLAUDE_PLUGIN_ROOT/bin/workbench-mesh`.
- Pass `--target "${CLAUDE_PROJECT_DIR:-$PWD}"` for commands that need a project.
- Support `start`, `status`, `who`, `invite`, `connect`, `room`, `message`, `ask`, `handoff`, `jobs`, `availability`, `doing`, `watch`, `open`.
- For `start --lan`, print hostname/mDNS, IP, port, local URL, and invite guidance.

- [ ] **Step 5: Add `/workbench:mesh` command**

`commands/mesh.md` must instruct Claude:

```markdown
---
description: Coordinate Claude sessions/leads/workers over the local/LAN Workbench Mesh command center
allowed-tools: ["Bash", "Read"]
---

Use this when the user asks to connect another Claude session, bring in another device, open a channel between leads, ask another lead/worker for status/help, hand off work, show who is working, or open the command center.

Run `${CLAUDE_PLUGIN_ROOT}/scripts/mesh.sh $ARGUMENTS`.

Prefer natural outcome routing:
- "talk to my MacBook Claude" -> status, start if needed, invite/connect instructions.
- "open a channel for leads" -> room create + message.
- "ask worker status" -> ask/status request.
- "show me the team" -> who/status.

Never expose LAN unless the user clearly asked to connect another machine or multiple users. Never expose public internet in this version.
```

- [ ] **Step 6: Add mesh skill**

`skills/mesh/SKILL.md` must cover:

- Use mesh for cross-session/device/teamlead communication.
- Users speak in outcomes; Claude maps to `/workbench:mesh`.
- Chat/status/help are first-class, not only task handoff.
- Use structured operations before prose.
- Public exposure is unavailable.
- Same-user local auth is automatic, LAN requires invite token.

- [ ] **Step 7: Update validation**

Extend `scripts/validate-plugin.sh` to warn/error if:

- `commands/mesh.md` exists but `bin/workbench-mesh` is missing or not executable.
- `scripts/mesh.sh` exists but fails `bash -n`.
- `skills/mesh/SKILL.md` is missing while `commands/mesh.md` exists.

- [ ] **Step 8: Run focused checks**

Run:

```bash
bash test/mesh-packaging.test.sh
bash test/command.test.sh
bash test/skills.test.sh
bash scripts/validate-plugin.sh
```

Expected: all pass.

- [ ] **Step 9: Commit**

```bash
git add bin scripts/mesh.sh commands/mesh.md skills/mesh/SKILL.md test/mesh-packaging.test.sh test/command.test.sh test/skills.test.sh scripts/validate-plugin.sh
git commit -m "feat(mesh): expose packaged binary through plugin commands"
```

---

### Task 6: Command Center UI

**Files:**
- Create: `crates/workbench-mesh/assets/index.html`
- Create: `crates/workbench-mesh/assets/app.js`
- Create: `crates/workbench-mesh/assets/style.css`
- Modify: `crates/workbench-mesh/src/server.rs`
- Create: `test/mesh-command-center.test.sh`

**Interfaces:**
- Produces: `GET /` command center HTML.
- Produces: `GET /assets/app.js` and `GET /assets/style.css`.
- UI consumes: `/api/state`, `/api/events`, `/api/invites`, `/api/events`.

- [ ] **Step 1: Write failing command center test**

Create `test/mesh-command-center.test.sh`:

```bash
#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
HOME_TMP="$(mktemp -d)"
PIDF="$TMP/mesh.pid"
trap 'kill "$(cat "$PIDF" 2>/dev/null)" >/dev/null 2>&1 || true; rm -rf "$TMP" "$HOME_TMP"' EXIT
fail=0
chk() { if eval "$2"; then echo "ok: $1"; else echo "FAIL: $1" >&2; fail=1; fi; }

bash "$HERE/scripts/init.sh" --name "MeshUI" --mission "Test." --target "$TMP" --profile full --level crew >/dev/null 2>&1
BIN="$HERE/target/debug/workbench-mesh"
"$BIN" auth bootstrap --target "$TMP" --home "$HOME_TMP" >/dev/null
"$BIN" serve --target "$TMP" --home "$HOME_TMP" --bind local --port 0 --pid-file "$PIDF" > "$TMP/mesh.log" 2>&1 &
for _ in $(seq 1 50); do [ -f "$TMP/.workbench/mesh/server.json" ] && break; sleep 0.1; done
PORT="$(sed -n 's/.*"port":\([0-9][0-9]*\).*/\1/p' "$TMP/.workbench/mesh/server.json" | head -1)"
TOKEN="$(sed -n 's/.*"local_token":"\([^"]*\)".*/\1/p' "$TMP/.workbench/mesh/server.json" | head -1)"

HTML="$(curl -fsS "http://127.0.0.1:$PORT/")"
chk "html names command center" "printf '%s' \"\$HTML\" | grep -q 'Workbench Mesh'"
chk "html includes leads view" "printf '%s' \"\$HTML\" | grep -q 'Leads'"
chk "html includes workers view" "printf '%s' \"\$HTML\" | grep -q 'Workers'"
chk "html includes rooms view" "printf '%s' \"\$HTML\" | grep -q 'Rooms'"
chk "html includes jobs view" "printf '%s' \"\$HTML\" | grep -q 'Jobs'"
chk "html includes invites view" "printf '%s' \"\$HTML\" | grep -q 'Invites'"

JS="$(curl -fsS "http://127.0.0.1:$PORT/assets/app.js")"
chk "app opens websocket" "printf '%s' \"\$JS\" | grep -q 'WebSocket'"
chk "app posts events" "printf '%s' \"\$JS\" | grep -q '/api/events'"

curl -fsS -X POST "http://127.0.0.1:$PORT/api/events" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"type":"message.sent","room":"repo:meshui","from":"ui:owner","payload":{"text":"hello leads"}}' >/dev/null

STATE="$(curl -fsS "http://127.0.0.1:$PORT/api/state" -H "Authorization: Bearer $TOKEN")"
chk "state includes ui message" "printf '%s' \"\$STATE\" | grep -q 'hello leads'"

[ "$fail" = 0 ] && echo "PASS: mesh-command-center" || { echo "mesh-command-center test failed"; exit 1; }
```

- [ ] **Step 2: Run and verify failure**

Run:

```bash
bash test/mesh-command-center.test.sh
```

Expected: fail because `/` and assets are missing.

- [ ] **Step 3: Build dense operational UI**

Implement a static HTML/CSS/JS UI with these sections visible in the first screen or tab bar:

```text
Overview
Leads
Workers
Rooms
Jobs
Tasks
Decisions
Invites
Audit
```

Design constraints:

- Keep it dense and operational; no landing page or marketing hero.
- Avoid nested cards; use full-width bands/tables/panels.
- Use stable dimensions for counters, rows, toolbar buttons, and status chips.
- Keep colors restrained and not dominated by one hue.
- No decorative gradient blobs/orbs.
- All controls must fit on mobile and desktop.

- [ ] **Step 4: Implement browser actions as API calls**

Minimum UI actions:

```text
Send message
Ask status
Request help
Create invite
Revoke invite
Approve decision
Deny decision
Reassign task
Stop job
Retry job
Adopt stale lead
Close lead
Set availability
```

Each action posts a structured event to `/api/events` or `/api/invites`. If backend support is not fully meaningful yet, it still records the event and updates the projected state.

- [ ] **Step 5: Run focused checks**

Run:

```bash
cargo test -p workbench-mesh
bash test/mesh-command-center.test.sh
```

Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add crates/workbench-mesh/assets crates/workbench-mesh/src/server.rs test/mesh-command-center.test.sh
git commit -m "feat(mesh): add command center UI"
```

---

### Task 7: Hooks, Context Injection, And Terminal Statusline

**Files:**
- Create: `hooks/bin/mesh-context.sh`
- Create: `hooks/bin/mesh-statusline.sh`
- Modify: `hooks/hooks.json`
- Modify: `hooks/bin/ground-session.sh`
- Modify: `hooks/bin/lead-purpose-nudge.sh`
- Create: `test/mesh-hooks.test.sh`
- Modify: `test/hooks.test.sh`

**Interfaces:**
- Produces: SessionStart/UserPromptSubmit mesh context.
- Produces: statusline text from cached snapshot without network access.

- [ ] **Step 1: Write failing hook/statusline test**

Create `test/mesh-hooks.test.sh`:

```bash
#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
HOME_TMP="$(mktemp -d)"
trap 'rm -rf "$TMP" "$HOME_TMP"' EXIT
fail=0
chk() { if eval "$2"; then echo "ok: $1"; else echo "FAIL: $1" >&2; fail=1; fi; }

bash "$HERE/scripts/init.sh" --name "MeshHooks" --mission "Test." --target "$TMP" --profile full --level crew >/dev/null 2>&1
mkdir -p "$HOME_TMP/mesh/statusline"
cat > "$HOME_TMP/mesh/statusline/meshhooks.json" <<'JSON'
{"project":"MeshHooks","current_actor":"checkout lead","availability":"busy","doing":"retry tests","active_count":3,"stale_count":1,"watched":["macbook testing 0042"],"unread_mentions":2}
JSON

OUT="$(WORKBENCH_HOME="$HOME_TMP" CLAUDE_PROJECT_DIR="$TMP" CLAUDE_PLUGIN_ROOT="$HERE" bash "$HERE/hooks/bin/mesh-statusline.sh")"
chk "statusline prints project" "printf '%s' \"\$OUT\" | grep -q 'workbench'"
chk "statusline prints actor" "printf '%s' \"\$OUT\" | grep -q 'checkout lead'"
chk "statusline prints team pulse" "printf '%s' \"\$OUT\" | grep -q '3 active'"
chk "statusline does not require server" "printf '%s' \"\$OUT\" | grep -q 'macbook testing 0042'"

printf '{"session_id":"sidmesh","prompt":"can you ask the macbook session for status?"}' \
  | WORKBENCH_HOME="$HOME_TMP" CLAUDE_PROJECT_DIR="$TMP" CLAUDE_PLUGIN_ROOT="$HERE" bash "$HERE/hooks/bin/mesh-context.sh" > "$TMP/mesh-context.json"
chk "mesh context emits valid json" "python3 -m json.tool '$TMP/mesh-context.json' >/dev/null"
chk "mesh context explains mesh commands" "grep -q '/workbench:mesh' '$TMP/mesh-context.json'"
chk "hooks json references mesh context" "grep -q 'mesh-context.sh' '$HERE/hooks/hooks.json'"

[ "$fail" = 0 ] && echo "PASS: mesh-hooks" || { echo "mesh-hooks test failed"; exit 1; }
```

- [ ] **Step 2: Run and verify failure**

Run:

```bash
bash test/mesh-hooks.test.sh
```

Expected: fail because hook scripts are missing.

- [ ] **Step 3: Implement non-blocking statusline**

`hooks/bin/mesh-statusline.sh` must:

- resolve project name or id
- read only cached files under `${WORKBENCH_HOME:-$HOME/.workbench}/mesh/statusline/`
- never call curl, the daemon, git, or long-running commands
- print a single compact line
- exit 0 if no snapshot exists

- [ ] **Step 4: Implement mesh context hook**

`hooks/bin/mesh-context.sh` must emit valid Claude hook JSON:

```json
{
  "hookSpecificOutput": {
    "hookEventName": "UserPromptSubmit",
    "additionalContext": "..."
  }
}
```

Context should include:

- mesh running or not when known from `.workbench/mesh/server.json`
- command center URLs when known
- active/stale counts from cached snapshot
- reminder that user asks outcomes, Claude calls `/workbench:mesh`

- [ ] **Step 5: Wire hooks**

Add `mesh-context.sh` to:

- `SessionStart` after `ground-session.sh`
- `UserPromptSubmit` alongside `lead-purpose-nudge.sh`

Keep hooks timeout at `10`.

- [ ] **Step 6: Run focused checks**

Run:

```bash
bash test/mesh-hooks.test.sh
bash test/hooks.test.sh
```

Expected: all pass.

- [ ] **Step 7: Commit**

```bash
git add hooks/hooks.json hooks/bin/mesh-context.sh hooks/bin/mesh-statusline.sh hooks/bin/ground-session.sh hooks/bin/lead-purpose-nudge.sh test/mesh-hooks.test.sh test/hooks.test.sh
git commit -m "feat(mesh): add context hooks and statusline"
```

---

### Task 8: Proven Outcome Test Suite

**Files:**
- Create: `test/mesh-plugin-outcome.test.sh`
- Modify: `test/all.sh`
- Modify: `test/e2e/run.sh`

**Interfaces:**
- Produces offline outcome tests that execute the same plugin command wrappers Claude uses.
- Produces gated live-plugin scenarios that drive real Claude Code through `/workbench:mesh`.

- [ ] **Step 1: Create offline plugin outcome test**

Create `test/mesh-plugin-outcome.test.sh`:

```bash
#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
HOME_TMP="$(mktemp -d)"
PIDF="$TMP/mesh.pid"
trap 'kill "$(cat "$PIDF" 2>/dev/null)" >/dev/null 2>&1 || true; rm -rf "$TMP" "$HOME_TMP"' EXIT
fail=0
chk() { if eval "$2"; then echo "ok: $1"; else echo "FAIL: $1" >&2; fail=1; fi; }

bash "$HERE/scripts/init.sh" --name "MeshOutcome" --mission "Test." --target "$TMP" --profile full --level crew >/dev/null 2>&1
cargo build -p workbench-mesh >/dev/null

export CLAUDE_PLUGIN_ROOT="$HERE"
export CLAUDE_PROJECT_DIR="$TMP"
export WORKBENCH_HOME="$HOME_TMP"

bash "$HERE/scripts/mesh.sh" start --local --port 0 --pid-file "$PIDF" > "$TMP/start.out"
chk "start prints command center url" "grep -q 'Command center:' '$TMP/start.out'"
chk "start prints local url" "grep -q '127.0.0.1' '$TMP/start.out'"

bash "$HERE/scripts/mesh.sh" availability busy --reason "running checkout tests" >/dev/null
bash "$HERE/scripts/mesh.sh" room lead:checkout >/dev/null
bash "$HERE/scripts/mesh.sh" message lead:checkout "what are you touching?" >/dev/null
bash "$HERE/scripts/mesh.sh" ask session:worker "status?" >/dev/null
bash "$HERE/scripts/mesh.sh" handoff 0042 session:worker >/dev/null
bash "$HERE/scripts/mesh.sh" invite --role worker --ttl-seconds 900 > "$TMP/invite.out"
bash "$HERE/scripts/mesh.sh" who > "$TMP/who.out"

chk "invite prints token" "grep -q '^token: wb_invite_' '$TMP/invite.out'"
chk "who shows local actor or events" "grep -Eq 'session|lead|worker|active' '$TMP/who.out'"
chk "event log contains lead chat" "grep -q 'message.sent' '$TMP/.workbench/mesh/events.jsonl'"
chk "event log contains status request" "grep -q 'message.request_status' '$TMP/.workbench/mesh/events.jsonl'"
chk "event log contains task handoff" "grep -q 'task.handoff' '$TMP/.workbench/mesh/events.jsonl'"
chk "audit contains invite" "grep -q 'invite.created' '$TMP/.workbench/mesh/audit.jsonl'"

STATUSLINE="$(bash "$HERE/hooks/bin/mesh-statusline.sh")"
chk "statusline shows busy state from outcome flow" "printf '%s' \"\$STATUSLINE\" | grep -qi 'busy\\|workbench'"

[ "$fail" = 0 ] && echo "PASS: mesh-plugin-outcome" || { echo "mesh-plugin-outcome test failed"; exit 1; }
```

- [ ] **Step 2: Add test to `test/all.sh`**

Add suites in dependency order:

```text
mesh-protocol mesh-auth mesh-service mesh-ops mesh-packaging mesh-command-center mesh-hooks mesh-plugin-outcome
```

Place them after `park` and before broader orchestration suites so failures are near the new feature.

- [ ] **Step 3: Extend live plugin e2e**

Add scenarios to `test/e2e/run.sh`:

```bash
note "11) /workbench:mesh starts local command center and prints URL"
D11="$(scaffold "E2E Mesh Start" crew)"
out="$(cd "$D11" && drive "$D11" 'Run /workbench:mesh start --local --port 0. Show me the command center URL. Do not expose LAN.')"
printf '%s' "$out" | grep -qiE 'command center|127\\.0\\.0\\.1|mesh' \
  && ok "mesh start reports local command center" \
  || bad "mesh start did not report command center"
rm -rf "$D11"

note "12) /workbench:mesh invite creates a worker invite"
D12="$(scaffold "E2E Mesh Invite" crew)"
out="$(cd "$D12" && drive "$D12" 'Run /workbench:mesh start --local --port 0, then create a worker invite. Show the token, role, expiry, host, IP and port.')"
printf '%s' "$out" | grep -qiE 'wb_invite_|role: worker|127\\.0\\.0\\.1|port|host' \
  && ok "mesh invite reports secure connection details" \
  || bad "mesh invite missing connection details"
rm -rf "$D12"

note "13) /workbench:mesh maps natural team intent to chat/status events"
D13="$(scaffold "E2E Mesh Natural" crew)"
out="$(cd "$D13" && drive "$D13" 'Use workbench mesh to open a checkout lead room, send a message asking what files are being touched, and show who is connected. Do it directly.')"
printf '%s' "$out" | grep -qiE 'checkout|message|who|lead|mesh' \
  && ok "mesh natural intent produces collaboration output" \
  || bad "mesh natural intent failed"
rm -rf "$D13"
```

- [ ] **Step 4: Run offline outcome suite**

Run:

```bash
bash test/mesh-plugin-outcome.test.sh
bash test/all.sh
```

Expected: `ALL TESTS PASS`.

- [ ] **Step 5: Run gated live-plugin suite when authenticated Claude is available**

Run:

```bash
WB_E2E=1 bash test/e2e/run.sh
```

Expected: `E2E PASS`.

If the environment lacks an authenticated `claude` CLI, the suite may print `SKIP`; record that in the implementation summary and do not claim live-plugin verification ran.

- [ ] **Step 6: Commit**

```bash
git add test/mesh-plugin-outcome.test.sh test/all.sh test/e2e/run.sh
git commit -m "test(mesh): prove plugin outcome flows"
```

---

### Task 9: CI, Release Packaging, And Docs

**Files:**
- Modify: `.github/workflows/ci.yml`
- Create: `.github/workflows/release-binaries.yml`
- Modify: `README.md`
- Modify: `docs/commands.md`
- Modify: `docs/concepts.md`
- Modify: `docs/configuration.md`
- Modify: `CHANGELOG.md`
- Modify: `scripts/validate-plugin.sh`

**Interfaces:**
- Produces CI that builds Rust, runs Rust tests, runs mesh shell suites, and validates plugin.
- Produces release workflow that builds target binaries into `bin/workbench-mesh.d/<target>/workbench-mesh` layout and attaches archives.

- [ ] **Step 1: Update CI for Rust**

Modify `.github/workflows/ci.yml`:

```yaml
      - name: Set up Rust
        uses: dtolnay/rust-toolchain@stable

      - name: Cache cargo
        uses: Swatinem/rust-cache@v2

      - name: Rust tests
        run: cargo test --workspace

      - name: Build mesh binary
        run: cargo build -p workbench-mesh
```

Keep the existing Python setup because current shell tests use `python3 -m json.tool`.

- [ ] **Step 2: Add release binary workflow**

Create `.github/workflows/release-binaries.yml`:

```yaml
name: Release mesh binaries

on:
  workflow_dispatch:
  push:
    tags:
      - "v*"

jobs:
  build:
    strategy:
      matrix:
        include:
          - os: ubuntu-latest
            target: x86_64-unknown-linux-gnu
          - os: ubuntu-latest
            target: aarch64-unknown-linux-gnu
          - os: macos-14
            target: aarch64-apple-darwin
          - os: macos-13
            target: x86_64-apple-darwin
    runs-on: ${{ matrix.os }}
    steps:
      - uses: actions/checkout@v4
      - uses: dtolnay/rust-toolchain@stable
        with:
          targets: ${{ matrix.target }}
      - uses: Swatinem/rust-cache@v2
      - run: cargo build --release -p workbench-mesh --target ${{ matrix.target }}
      - run: |
          mkdir -p "dist/workbench/bin/workbench-mesh.d/${{ matrix.target }}"
          cp "target/${{ matrix.target }}/release/workbench-mesh" "dist/workbench/bin/workbench-mesh.d/${{ matrix.target }}/workbench-mesh"
          cp bin/workbench-mesh dist/workbench/bin/workbench-mesh
          chmod +x dist/workbench/bin/workbench-mesh dist/workbench/bin/workbench-mesh.d/${{ matrix.target }}/workbench-mesh
          tar -C dist -czf "workbench-mesh-${{ matrix.target }}.tar.gz" workbench
      - uses: actions/upload-artifact@v4
        with:
          name: workbench-mesh-${{ matrix.target }}
          path: workbench-mesh-${{ matrix.target }}.tar.gz
```

If cross-compiling `aarch64-unknown-linux-gnu` needs linker setup, add `cross` in the implementation PR rather than disabling that target.

- [ ] **Step 3: Strengthen plugin validation**

`scripts/validate-plugin.sh` should verify:

- `bin/workbench-mesh` exists and is executable.
- `commands/mesh.md` references `scripts/mesh.sh`.
- `scripts/mesh.sh` passes `bash -n`.
- `Cargo.toml` exists when mesh command exists.
- Release source tree contains either packaged binaries or a clear launcher error. For dev source, missing platform binaries are allowed if Cargo source exists.

- [ ] **Step 4: Update docs**

Docs must explain:

- Natural user phrasing: "talk to my MacBook Claude session", "open a lead channel", "ask worker status".
- `/workbench:mesh start --local` and `/workbench:mesh start --lan`.
- Auth model: same-user local credential, LAN invite token, public deferred.
- Command center URLs show hostname, `.local`, raw IP, and port.
- Statusline integration and cached snapshot.
- Actor hierarchy: leads, subagents, workers, jobs.
- Test suite: offline shell/Rust, command-center API, plugin outcome, gated live e2e.

Add `[Unreleased]` changelog entry:

```markdown
## [Unreleased]

### Added
- Workbench Mesh design implementation: Rust control-plane binary, local/LAN command center, authenticated invites, structured lead/worker rooms, actor hierarchy, statusline presence, and outcome-level plugin tests.
```

- [ ] **Step 5: Run final verification**

Run:

```bash
cargo fmt --check
cargo test --workspace
cargo build -p workbench-mesh
bash test/all.sh
bash scripts/validate-plugin.sh
git diff --check
```

Expected:

- Rust format check passes.
- Rust tests pass.
- Rust binary builds.
- Shell suite prints `ALL TESTS PASS`.
- Plugin validation prints publishable.
- No whitespace errors.

- [ ] **Step 6: Commit**

```bash
git add .github/workflows/ci.yml .github/workflows/release-binaries.yml README.md docs/commands.md docs/concepts.md docs/configuration.md CHANGELOG.md scripts/validate-plugin.sh
git commit -m "docs(mesh): document Rust command center packaging"
```

---

## Outcome Verification Contract

Implementation is not complete until these prove the actual plugin outcome:

```bash
cargo fmt --check
cargo test --workspace
cargo build -p workbench-mesh
bash test/mesh-protocol.test.sh
bash test/mesh-auth.test.sh
bash test/mesh-service.test.sh
bash test/mesh-ops.test.sh
bash test/mesh-packaging.test.sh
bash test/mesh-command-center.test.sh
bash test/mesh-hooks.test.sh
bash test/mesh-plugin-outcome.test.sh
bash test/all.sh
bash scripts/validate-plugin.sh
git diff --check
```

Live plugin verification should run when an authenticated Claude CLI is available:

```bash
WB_E2E=1 bash test/e2e/run.sh
```

The implementation summary must state whether live e2e ran or skipped. Do not describe the mesh as fully proven by the plugin host unless `WB_E2E=1 bash test/e2e/run.sh` actually ran and passed.

## Scope Deferred

- Public internet exposure.
- WebRTC DataChannels.
- gRPC/protobuf transport.
- MCP/Channel adapters.
- Bridge federation.
- Windows native binary packaging outside WSL.
- Rich terminal log streaming from child Claude jobs beyond actor/job status events.

## Plan Self-Review

- Spec coverage: local/LAN service, auth, invites, JSON/WebSocket, command center, lead chats, actor hierarchy, statusline, natural intent, packaging, and outcome tests are each mapped to tasks.
- Testing coverage: protocol, auth, service, operations, UI, hooks/statusline, packaging, offline plugin outcome, full offline suite, and gated live-plugin e2e are all required.
- Type consistency: protocol envelope fields use `v`, `id`, `seq`, `type`, `room`, `from`, `to`, `ts`, `payload` throughout; actor/session/task event names match the design spec.
