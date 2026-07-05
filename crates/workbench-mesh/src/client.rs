use std::collections::BTreeSet;
use std::path::PathBuf;
use std::time::Instant;

use anyhow::{Context, Result};
use reqwest::{Client, Url};
use serde_json::{json, Value};

use crate::auth;
use crate::protocol::EventEnvelope;
use crate::server::{read_server_metadata, write_server_metadata, ServerMetadata};
use crate::statusline;
use crate::store::MeshStore;

const DEFAULT_ACTOR: &str = "session:lead";
const ACTOR_ENV_VAR: &str = "WORKBENCH_MESH_ACTOR";

/// Resolves which actor identity a CLI-invoked mesh command should post as:
/// an explicit `--as <name>` wins, then the `WORKBENCH_MESH_ACTOR` env var
/// (so a real dedicated Claude/Codex process can export it once and have
/// every mesh call self-identify), then the historical hardcoded default.
/// Without this, every separate process posting to mesh looked identical.
fn resolve_actor(explicit: Option<&str>) -> String {
    resolve_actor_from(explicit, std::env::var(ACTOR_ENV_VAR).ok().as_deref())
}

/// Pure resolution logic, factored out so tests can supply a synthetic env
/// value instead of mutating the real process environment (which would race
/// under the default multi-threaded test harness).
fn resolve_actor_from(explicit: Option<&str>, env_value: Option<&str>) -> String {
    if let Some(name) = explicit {
        if !name.trim().is_empty() {
            return name.to_string();
        }
    }
    if let Some(name) = env_value {
        if !name.trim().is_empty() {
            return name.to_string();
        }
    }
    DEFAULT_ACTOR.to_string()
}

/// Normalizes Rust's `std::env::consts::OS` ("macos"/"linux"/"windows"/...)
/// to the small set of platform names Workbench cares about for dispatch
/// decisions, defaulting unrecognized values to "unknown" rather than
/// leaking a raw, unstable string into the protocol.
fn detect_platform() -> String {
    normalize_platform(std::env::consts::OS)
}

fn normalize_platform(raw: &str) -> String {
    match raw {
        "macos" => "macos",
        "windows" => "windows",
        "linux" => "linux",
        _ => "unknown",
    }
    .to_string()
}

/// Capabilities a platform brings for dispatch purposes — e.g. only macOS
/// can run the iOS Simulator, so an iOS QA task should never be handed to a
/// Linux/Windows session. Auto-derived from platform; `--capability` on the
/// CLI can add project-specific extras (a GPU box, a specific SDK) on top.
fn default_capabilities(platform: &str) -> Vec<String> {
    match platform {
        "macos" => vec![
            "macos-native".to_string(),
            "ios-simulator".to_string(),
            "android-emulator".to_string(),
        ],
        "windows" => vec!["windows-native".to_string()],
        "linux" => vec!["linux-native".to_string(), "android-emulator".to_string()],
        _ => Vec::new(),
    }
}

/// Combines the platform's auto-derived capabilities with any project- or
/// session-specific extras from `--capability`, de-duplicated and sorted so
/// repeated heartbeats produce a stable payload (easier to diff/test, and
/// avoids the dashboard flickering on ordering alone).
fn merge_capabilities(platform: &str, extra: Vec<String>) -> Vec<String> {
    let mut caps = default_capabilities(platform);
    for c in extra {
        let c = c.trim();
        if !c.is_empty() && !caps.iter().any(|existing| existing == c) {
            caps.push(c.to_string());
        }
    }
    caps.sort();
    caps
}

pub async fn status(project_root: PathBuf, home: Option<PathBuf>) -> Result<()> {
    auth::require_local_project_credential(&project_root, home.clone())?;
    let token = auth::local_project_token(&project_root, home)?;
    let metadata = read_server_metadata(&project_root)?;
    let state = get_state(&metadata, &token).await?;
    let event_count = state
        .get("event_count")
        .and_then(Value::as_u64)
        .unwrap_or(0);
    let actor_count = state
        .get("connected_actor_count")
        .and_then(Value::as_u64)
        .unwrap_or(0);
    println!("mode: {}", metadata.mode);
    println!("url: {}", base_url(&metadata));
    println!("connected_actor_count: {actor_count}");
    println!("event_count: {event_count}");
    Ok(())
}

pub async fn who(project_root: PathBuf, home: Option<PathBuf>) -> Result<()> {
    auth::require_local_project_credential(&project_root, home.clone())?;
    let token = auth::local_project_token(&project_root, home)?;
    let metadata = read_server_metadata(&project_root)?;
    let state = get_state(&metadata, &token).await?;
    if let Some(actors) = state.get("actors").and_then(Value::as_array) {
        for actor in actors {
            if let Some(actor) = actor.as_str() {
                // System identities (invite/device plumbing) are not the
                // team — `devices` lists enrolled machines explicitly.
                if actor.starts_with("auth:") || actor.starts_with("device:") {
                    continue;
                }
                println!("{actor}");
            }
        }
    }
    Ok(())
}

pub async fn bench(project_root: PathBuf, home: Option<PathBuf>, messages: u64) -> Result<()> {
    let token = auth::local_mutating_project_token(&project_root, home)?;
    let metadata = read_server_metadata(&project_root)?;
    let client = mesh_http_client(&metadata)?;
    let mut latencies = Vec::with_capacity(messages as usize);
    for idx in 0..messages {
        let started = Instant::now();
        client
            .post(format!("{}/api/events", base_url(&metadata)))
            .bearer_auth(&token)
            .json(&json!({
                "type": "message.sent",
                "room": "repo:bench",
                "from": "session:bench",
                "payload": { "idx": idx },
            }))
            .send()
            .await
            .context("post bench event")?
            .error_for_status()
            .context("bench event rejected")?;
        latencies.push(started.elapsed().as_secs_f64() * 1000.0);
    }
    latencies.sort_by(|left, right| left.total_cmp(right));
    let p95 = percentile(&latencies, 0.95);
    println!("messages={messages} p95_ms={p95:.3}");
    Ok(())
}

const REMOTE_ERROR_MAX_LEN: usize = 200;

/// A remote (possibly hostile or compromised) mesh server can put anything it
/// wants in the `error` field of an invite-accept response, and that string
/// flows straight into a message printed to the connecting user's terminal —
/// and often into a Claude session transcript driving `connect`. Strip every
/// control character (ANSI/OSC escapes, terminal title spoofing, OSC 52
/// clipboard injection, etc.) and cap the length so a hostile server can't
/// inject terminal sequences or flood the screen with an unbounded string.
fn sanitize_remote_error_message(message: &str) -> String {
    let filtered: String = message.chars().filter(|c| !c.is_control()).collect();
    let truncated: String = filtered.chars().take(REMOTE_ERROR_MAX_LEN).collect();
    if filtered.chars().count() > REMOTE_ERROR_MAX_LEN {
        format!("{truncated}... (truncated)")
    } else {
        truncated
    }
}

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
    let local_project = auth::project_id_for(&project_root)?;
    let response = mesh_http_client(&metadata)?
        .post(format!("{}/api/invites/accept", base_url(&metadata)))
        .json(&json!({
            "token": token,
            "device": device,
            "expected_project": local_project,
        }))
        .send()
        .await
        .context("post remote invite accept")?;
    if !response.status().is_success() {
        let status = response.status();
        let body: Value = response.json().await.unwrap_or_default();
        let message = body
            .get("error")
            .and_then(Value::as_str)
            .unwrap_or("request failed");
        let sanitized = sanitize_remote_error_message(message);
        anyhow::bail!("remote invite rejected ({status}): {sanitized}");
    }
    let credential: auth::ProjectCredential = response
        .json()
        .await
        .context("parse remote invite credential")?;
    if credential.project != local_project {
        anyhow::bail!(
            "remote project mismatch: expected {local_project}, got {}",
            credential.project
        );
    }
    let credential_path = auth::persist_project_credential(home, &device, &credential)?;
    write_server_metadata(&project_root, &metadata)?;
    println!("device {} connected", auth::sanitize_device_name(&device));
    println!("project: {}", credential.project);
    println!("role: {}", credential.role);
    println!("url: {}", base_url(&metadata));
    println!("credential: {}", credential_path.display());
    Ok(())
}

pub(crate) fn remote_metadata_from_url(url: &str) -> Result<ServerMetadata> {
    let parsed = Url::parse(url).context("parse remote mesh URL")?;
    if parsed.scheme() != "http" {
        anyhow::bail!("remote mesh URL must use http");
    }
    if !parsed.username().is_empty()
        || parsed.password().is_some()
        || parsed.query().is_some()
        || parsed.fragment().is_some()
        || parsed.path() != "/"
    {
        anyhow::bail!(
            "remote mesh URL must be http://host:port without userinfo, path, query, or fragment"
        );
    }
    let host = parsed
        .host_str()
        .ok_or_else(|| anyhow::anyhow!("remote mesh URL requires a host"))?
        .to_string();
    let port = parsed
        .port()
        .ok_or_else(|| anyhow::anyhow!("remote mesh URL must be http://host:port"))?;
    Ok(ServerMetadata {
        mode: "remote".to_string(),
        host: host.clone(),
        port,
        hostname: host.clone(),
        mdns: if host.ends_with(".local") {
            host.clone()
        } else {
            String::new()
        },
        lan_ips: Vec::new(),
        local_token: String::new(),
        started_by: "unknown".to_string(),
        started_at: String::new(),
        tls_fingerprint: None,
    })
}

pub async fn list_devices(project_root: PathBuf, home: Option<PathBuf>) -> Result<()> {
    let token = auth::local_operator_project_token(&project_root, home)?;
    let metadata = read_server_metadata(&project_root)?;
    let body: Value = mesh_http_client(&metadata)?
        .get(format!("{}/api/devices", base_url(&metadata)))
        .bearer_auth(&token)
        .send()
        .await
        .context("get daemon devices")?
        .error_for_status()
        .context("daemon devices rejected")?
        .json()
        .await
        .context("parse daemon devices")?;
    if let Some(devices) = body.get("devices").and_then(Value::as_array) {
        for device in devices {
            println!(
                "{} role={} revoked={}",
                device.get("device").and_then(Value::as_str).unwrap_or("-"),
                device.get("role").and_then(Value::as_str).unwrap_or("-"),
                device
                    .get("revoked_at")
                    .map(|value| !value.is_null())
                    .unwrap_or(false)
            );
        }
    }
    Ok(())
}

pub async fn revoke_device(
    project_root: PathBuf,
    home: Option<PathBuf>,
    device: String,
) -> Result<()> {
    let token = auth::local_operator_project_token(&project_root, home)?;
    let metadata = read_server_metadata(&project_root)?;
    mesh_http_client(&metadata)?
        .post(format!("{}/api/devices/revoke", base_url(&metadata)))
        .bearer_auth(&token)
        .json(&json!({ "device": device }))
        .send()
        .await
        .context("post daemon device revoke")?
        .error_for_status()
        .context("daemon device revoke rejected")?;
    println!("device revoked");
    Ok(())
}

/// Room names reserved for internal use — `team` is the implicit all-hands
/// broadcast room and `tasks` backs the coordination board. Letting a user
/// `create-room team` would silently start posting `room.created` noise into
/// (and inviting confusion with) a room every dashboard/CLI surface already
/// treats as special, so this is a hard reject rather than a warning.
const RESERVED_ROOMS: &[&str] = &["team", "tasks"];

pub async fn create_room(
    project_root: PathBuf,
    home: Option<PathBuf>,
    name: String,
    from: Option<String>,
) -> Result<()> {
    if RESERVED_ROOMS.contains(&name.as_str()) {
        anyhow::bail!(
            "'{name}' is a reserved room name (used internally for {}); choose a different name",
            RESERVED_ROOMS.join("/")
        );
    }
    // Gate on credentials *before* touching the store at all: the
    // existing-room snapshot below opens the local store (creating its
    // files as a side effect) even for a read-only scan, so it must not
    // run ahead of the same auth check `append_or_post_event` performs —
    // otherwise a rejected create (bad/missing credential) would still
    // leave mesh files behind. See `send_message` for the same pattern.
    auth::require_local_mutating_project_credential(&project_root, home.clone())?;
    // Best-effort, non-blocking, same reasoning as `unknown_actor_warning`:
    // snapshot *before* the event is posted, since the `room.created` event
    // about to be appended would itself make the room "exist" if checked
    // after. There is no dedicated room registry (rooms are derived purely
    // by scanning `event.room` across the log, same as `known_actors`
    // scans `event.from`/`event.to`) — re-creating/re-joining a room that
    // already exists by name is a legitimate way to keep posting to it, so
    // this warns rather than rejects. Reserved names above still hard-reject.
    let warning = existing_room_warning(&project_root, home.clone(), &name).await;
    let event = append_or_post_event(
        &project_root,
        home,
        "room.created",
        &name,
        &resolve_actor(from.as_deref()),
        None,
        json!({ "name": name }),
    )
    .await?;
    println!("room: created {} seq={}", event.room, event.seq);
    emit_warning(warning);
    Ok(())
}

pub async fn send_message(
    project_root: PathBuf,
    home: Option<PathBuf>,
    to: String,
    text: String,
    from: Option<String>,
) -> Result<()> {
    // Gate on credentials *before* touching the store at all: the
    // known-actors snapshot below opens the local store (creating its
    // files as a side effect) even for a read-only scan, so it must not
    // run ahead of the same auth check `append_or_post_event` performs —
    // otherwise a rejected send (bad/missing credential) would still leave
    // mesh files behind.
    auth::require_local_mutating_project_credential(&project_root, home.clone())?;
    // Snapshot whether `to` has any *prior* history before this event lands —
    // see `unknown_actor_warning`'s doc comment for why this must be taken
    // before, not after, the send.
    let warning = unknown_actor_warning(&project_root, home.clone(), &to).await;
    let event = append_or_post_event(
        &project_root,
        home,
        "message.sent",
        &room_for_target(&to),
        &resolve_actor(from.as_deref()),
        Some(&to),
        json!({ "text": text }),
    )
    .await?;
    println!("message: sent seq={}", event.seq);
    emit_warning(warning);
    Ok(())
}

pub async fn ask_status(
    project_root: PathBuf,
    home: Option<PathBuf>,
    to: String,
    question: String,
    from: Option<String>,
) -> Result<()> {
    // See `send_message` for why the auth gate must run before the
    // known-actors snapshot touches the store.
    auth::require_local_mutating_project_credential(&project_root, home.clone())?;
    let warning = unknown_actor_warning(&project_root, home.clone(), &to).await;
    let event = append_or_post_event(
        &project_root,
        home,
        "message.request_status",
        &room_for_target(&to),
        &resolve_actor(from.as_deref()),
        Some(&to),
        json!({ "question": question }),
    )
    .await?;
    println!("ask: sent seq={}", event.seq);
    emit_warning(warning);
    Ok(())
}

pub async fn handoff_task(
    project_root: PathBuf,
    home: Option<PathBuf>,
    task_id: String,
    to: String,
    from: Option<String>,
) -> Result<()> {
    let event = append_or_post_event(
        &project_root,
        home,
        "task.handoff",
        "tasks",
        &resolve_actor(from.as_deref()),
        Some(&to),
        json!({ "task_id": task_id }),
    )
    .await?;
    println!("handoff: sent seq={}", event.seq);
    Ok(())
}

/// Provider ("claude"/"codex") and model ("sonnet"/"gpt-5"/…) cannot be
/// auto-detected from inside a session, so they are always explicit:
/// flag first, then env var, then "unknown".
fn resolve_identity_field(explicit: Option<String>, env_var: &str) -> String {
    explicit
        .filter(|value| !value.trim().is_empty())
        .or_else(|| {
            std::env::var(env_var)
                .ok()
                .filter(|value| !value.trim().is_empty())
        })
        .unwrap_or_else(|| "unknown".to_string())
}

#[allow(clippy::too_many_arguments)]
pub async fn set_availability(
    project_root: PathBuf,
    home: Option<PathBuf>,
    state: String,
    reason: Option<String>,
    from: Option<String>,
    platform: Option<String>,
    extra_capabilities: Vec<String>,
    provider: Option<String>,
    model: Option<String>,
) -> Result<()> {
    const VALID_AVAILABILITY_STATES: &[&str] = &["available", "busy", "blocked", "lead", "unknown"];
    if !VALID_AVAILABILITY_STATES.contains(&state.as_str()) {
        anyhow::bail!(
            "invalid availability state '{state}' — must be one of: {}",
            VALID_AVAILABILITY_STATES.join(", ")
        );
    }
    let platform = platform.unwrap_or_else(detect_platform);
    let capabilities = merge_capabilities(&platform, extra_capabilities);
    let provider = resolve_identity_field(provider, "WORKBENCH_MESH_PROVIDER");
    let model = resolve_identity_field(model, "WORKBENCH_MESH_MODEL");
    let event = append_or_post_event(
        &project_root,
        home,
        "presence.heartbeat",
        "presence",
        &resolve_actor(from.as_deref()),
        None,
        json!({
            "availability": state,
            "reason": reason,
            "platform": platform,
            "capabilities": capabilities,
            "provider": provider,
            "model": model,
        }),
    )
    .await?;
    println!("availability: updated seq={}", event.seq);
    Ok(())
}

#[allow(clippy::too_many_arguments)]
pub async fn set_doing(
    project_root: PathBuf,
    home: Option<PathBuf>,
    text: String,
    from: Option<String>,
    platform: Option<String>,
    extra_capabilities: Vec<String>,
    provider: Option<String>,
    model: Option<String>,
) -> Result<()> {
    let platform = platform.unwrap_or_else(detect_platform);
    let capabilities = merge_capabilities(&platform, extra_capabilities);
    let provider = resolve_identity_field(provider, "WORKBENCH_MESH_PROVIDER");
    let model = resolve_identity_field(model, "WORKBENCH_MESH_MODEL");
    let event = append_or_post_event(
        &project_root,
        home,
        "actor.status",
        "presence",
        &resolve_actor(from.as_deref()),
        None,
        json!({
            "current_step": text,
            "platform": platform,
            "capabilities": capabilities,
            "provider": provider,
            "model": model,
        }),
    )
    .await?;
    println!("doing: updated seq={}", event.seq);
    Ok(())
}

/// Tail a session's structured CLI stream into the mesh.
///
/// Reads `claude -p --output-format stream-json` / `codex exec --json`
/// lines on stdin, tees every line through to stdout unchanged (so the
/// tailer can sit inside an existing pipeline), and appends one
/// `output.chunk` event per extracted boundary into the per-agent
/// `output:<actor>` room. Diagnostics go to stderr only — stdout stays
/// bit-identical to the wrapped stream. Append failures are warnings, not
/// fatal: the tailer must never take down the session it observes.
pub async fn tail_stream(
    project_root: PathBuf,
    home: Option<PathBuf>,
    from: Option<String>,
    provider: Option<String>,
    model: Option<String>,
) -> Result<()> {
    use tokio::io::{AsyncBufReadExt, BufReader};

    let actor = resolve_actor(from.as_deref());
    let room = format!("output:{actor}");
    let platform = detect_platform();
    let capabilities = merge_capabilities(&platform, Vec::new());
    let provider = resolve_identity_field(provider, "WORKBENCH_MESH_PROVIDER");
    let model = resolve_identity_field(model, "WORKBENCH_MESH_MODEL");

    // Announce presence once so the actor appears on the bench immediately;
    // every subsequent output.chunk refreshes its liveness on the dashboard.
    match append_or_post_event(
        &project_root,
        home.clone(),
        "presence.heartbeat",
        "presence",
        &actor,
        None,
        json!({
            "availability": "busy",
            "reason": "tailing session output",
            "platform": platform,
            "capabilities": capabilities,
            "provider": provider,
            "model": model,
        }),
    )
    .await
    {
        Ok(event) => eprintln!("tail: {actor} on the bench (seq={})", event.seq),
        Err(error) => eprintln!("tail: presence heartbeat failed: {error:#}"),
    }

    let stdin = BufReader::new(tokio::io::stdin());
    let mut lines = stdin.lines();
    let mut forwarded: u64 = 0;
    while let Some(line) = lines.next_line().await.context("read stream line")? {
        println!("{line}");
        for chunk in crate::tailer::extract_chunks(&line) {
            let mut payload = json!({ "kind": chunk.kind, "summary": chunk.summary });
            if let Some(tool) = &chunk.tool {
                payload["tool"] = json!(tool);
            }
            match append_or_post_event(
                &project_root,
                home.clone(),
                "output.chunk",
                &room,
                &actor,
                None,
                payload,
            )
            .await
            {
                Ok(_) => forwarded += 1,
                Err(error) => eprintln!("tail: dropped chunk: {error:#}"),
            }
        }
    }
    eprintln!("tail: stream ended — {forwarded} output.chunk events into {room}");
    Ok(())
}

/// Publish a lightweight activity signal (reading/typing/idle) so dashboards
/// can show live engagement between full messages. When `ack_of` is `Some`,
/// posts a `message.read` receipt in the same room as the referenced event
/// instead of a plain presence heartbeat.
pub async fn set_activity(
    project_root: PathBuf,
    home: Option<PathBuf>,
    state: String,
    from: Option<String>,
    ack_of: Option<u64>,
) -> Result<()> {
    const VALID_ACTIVITY_STATES: &[&str] = &["typing", "reading", "idle"];
    if !VALID_ACTIVITY_STATES.contains(&state.as_str()) {
        anyhow::bail!(
            "invalid activity state '{state}' — must be one of: {}",
            VALID_ACTIVITY_STATES.join(", ")
        );
    }
    let actor = resolve_actor(from.as_deref());
    let event = match ack_of {
        Some(seq) => {
            let referenced = referenced_event(&project_root, home.clone(), seq).await?;
            append_or_post_ack(
                &project_root,
                home,
                "message.read",
                &referenced.room,
                &actor,
                seq,
            )
            .await?
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
            let response = mesh_http_client(&metadata)?
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
    MeshStore::open(project_root)?.append_event_with_ack(
        event_type,
        room,
        from,
        None,
        json!({}),
        Some(ack_of),
    )
}

pub async fn watch_actor(
    project_root: PathBuf,
    home: Option<PathBuf>,
    actor: String,
    from: Option<String>,
) -> Result<()> {
    // The dashboard's chat ingest falls back to an empty string when a
    // `message.sent` payload has no `text` (live.js: `p.text || p.question
    // || ...`), so without a `text` field this rendered as a blank bubble.
    // The bubble is attributed to `from` (the watcher), so the text reads
    // as that actor's own action: "<watcher> is checking in on <actor>'s
    // work" — third-person, matching `task.handoff`'s "<who> handoff —
    // <task_id>" convention for system-generated activity lines.
    //
    // See `send_message` for why the auth gate must run before the
    // known-actors snapshot touches the store.
    auth::require_local_mutating_project_credential(&project_root, home.clone())?;
    let warning = unknown_actor_warning(&project_root, home.clone(), &actor).await;
    let event = append_or_post_event(
        &project_root,
        home,
        "message.sent",
        &room_for_target(&actor),
        &resolve_actor(from.as_deref()),
        Some(&actor),
        json!({
            "intent": "watch",
            "actor": actor.clone(),
            "text": format!("is checking in on {actor}'s work"),
        }),
    )
    .await?;
    println!("watch: added seq={}", event.seq);
    emit_warning(warning);
    Ok(())
}

pub fn print_jobs(project_root: PathBuf, home: Option<PathBuf>, since: u64) -> Result<()> {
    for event in job_events(project_root, home, since)? {
        println!("{}", serde_json::to_string(&event)?);
    }
    Ok(())
}

pub fn job_events(
    project_root: PathBuf,
    home: Option<PathBuf>,
    since: u64,
) -> Result<Vec<EventEnvelope>> {
    auth::require_local_project_credential(&project_root, home)?;
    let store = MeshStore::open(project_root)?;
    Ok(store
        .list_events_since(since)?
        .into_iter()
        .filter(|event| event.event_type.starts_with("job."))
        .collect())
}

pub async fn spawn_actor(
    project_root: PathBuf,
    home: Option<PathBuf>,
    kind: String,
    parent: String,
    purpose: String,
    task_id: Option<String>,
) -> Result<()> {
    let actor = spawned_actor_id(&kind, task_id.as_deref());
    let event = append_or_post_event(
        &project_root,
        home,
        "actor.spawned",
        "actors",
        &parent,
        Some(&actor),
        json!({
            "actor": actor,
            "kind": kind,
            "parent": parent,
            "purpose": purpose,
            "task_id": task_id,
        }),
    )
    .await?;
    println!("actor: spawned seq={}", event.seq);
    Ok(())
}

pub fn snapshot_statusline(project_root: PathBuf, home: Option<PathBuf>) -> Result<()> {
    auth::require_local_project_credential(&project_root, home.clone())?;
    statusline::write_snapshot(&project_root, home)?;
    Ok(())
}

async fn append_or_post_event(
    project_root: &std::path::Path,
    home: Option<PathBuf>,
    event_type: &str,
    room: &str,
    from: &str,
    to: Option<&str>,
    payload: Value,
) -> Result<crate::protocol::EventEnvelope> {
    auth::require_local_mutating_project_credential(project_root, home.clone())?;
    if let Ok(metadata) = read_server_metadata(project_root) {
        if metadata.mode == "remote" {
            let token = auth::local_mutating_project_token(project_root, home)?;
            let response = mesh_http_client(&metadata)?
                .post(format!("{}/api/events", base_url(&metadata)))
                .bearer_auth(&token)
                .json(&json!({
                    "type": event_type,
                    "room": room,
                    "from": from,
                    "to": to,
                    "payload": payload,
                }))
                .send()
                .await
                .context("post remote daemon event")?
                .error_for_status()
                .context("remote daemon event rejected")?;
            return response.json().await.context("parse remote daemon event");
        }
    }
    MeshStore::open(project_root)?.append_event(event_type, room, from, to, payload)
}

/// Best-effort lookup of actors with any prior history in this mesh —
/// powers only the non-blocking "unknown target" warning below, never a
/// send-time gate. Follows the same local-vs-remote dispatch as
/// `append_or_post_event`: scan the local store directly in local/lan
/// mode, or ask the remote daemon's `/api/state` in remote mode.
async fn known_actors(
    project_root: &std::path::Path,
    home: Option<PathBuf>,
) -> Result<BTreeSet<String>> {
    if let Ok(metadata) = read_server_metadata(project_root) {
        if metadata.mode == "remote" {
            let token = auth::local_project_token(project_root, home)?;
            let state = get_state(&metadata, &token).await?;
            let actors = state
                .get("actors")
                .and_then(Value::as_array)
                .map(|values| {
                    values
                        .iter()
                        .filter_map(Value::as_str)
                        .map(str::to_string)
                        .collect()
                })
                .unwrap_or_default();
            return Ok(actors);
        }
    }
    MeshStore::open(project_root)?.known_actors()
}

/// Best-effort, non-blocking: computes the "unknown target" warning message
/// for `to`, or `None` if `to` is already known (or the check itself
/// failed — e.g. an unreachable remote daemon). Returns the message rather
/// than printing it directly, so callers control exactly when it's
/// surfaced and tests can assert on it without capturing stderr.
///
/// MUST be snapshotted *before* the event is posted, not after: the event
/// about to be sent will itself name `to` as its addressee, so a scan taken
/// after the post would always find `to` "known" (it's the recipient of the
/// very event just appended) and the warning would never fire. Taking the
/// snapshot first captures only genuinely prior history. Any error from the
/// lookup is swallowed here — it must never propagate as a send failure,
/// and the caller must go on to post the event regardless of this result.
/// There is no actor-registration step in this system, so a hard reject
/// here would break the first legitimate message to a brand-new actor.
async fn unknown_actor_warning(
    project_root: &std::path::Path,
    home: Option<PathBuf>,
    to: &str,
) -> Option<String> {
    let known = known_actors(project_root, home).await.ok()?;
    if known.contains(to) {
        return None;
    }
    Some(format!(
        "mesh: note — '{to}' has no prior activity in this mesh; double-check the name"
    ))
}

/// Best-effort, non-blocking: `Some(message)` if a room named `name` already
/// has at least one event in the log, `None` otherwise (or if the lookup
/// itself failed — e.g. an unreachable remote daemon). Mirrors
/// `unknown_actor_warning`'s shape: there is no dedicated room registry, so
/// this scans the same event log (`event.room`) that `known_actors` scans
/// for `event.from`/`event.to`. MUST be snapshotted *before* the
/// `room.created` event is posted for the same reason `unknown_actor_warning`
/// snapshots before its send — after posting, the room would always appear
/// to "already exist" (it now contains the very event just appended).
async fn existing_room_warning(
    project_root: &std::path::Path,
    home: Option<PathBuf>,
    name: &str,
) -> Option<String> {
    let exists = if let Ok(metadata) = read_server_metadata(project_root) {
        if metadata.mode == "remote" {
            let token = auth::local_project_token(project_root, home).ok()?;
            let state = get_state(&metadata, &token).await.ok()?;
            state
                .get("events")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
                .any(|event| event.get("room").and_then(Value::as_str) == Some(name))
        } else {
            local_room_exists(project_root, name)?
        }
    } else {
        local_room_exists(project_root, name)?
    };
    if !exists {
        return None;
    }
    Some(format!(
        "mesh: note — room '{name}' already exists; posting to it rather than starting a new one"
    ))
}

fn local_room_exists(project_root: &std::path::Path, name: &str) -> Option<bool> {
    Some(
        MeshStore::open(project_root)
            .ok()?
            .list_events_since(0)
            .ok()?
            .iter()
            .any(|event| event.room == name),
    )
}

/// Prints a warning computed by `unknown_actor_warning` or
/// `existing_room_warning`, if any. Call only after the corresponding
/// action has already succeeded, so the warning never appears in place of
/// (or ahead of) a successful confirmation.
fn emit_warning(warning: Option<String>) {
    if let Some(warning) = warning {
        eprintln!("{warning}");
    }
}

async fn get_state(metadata: &crate::server::ServerMetadata, token: &str) -> Result<Value> {
    let response = mesh_http_client(metadata)?
        .get(format!("{}/api/state", base_url(metadata)))
        .bearer_auth(token)
        .send()
        .await
        .context("get daemon state")?
        .error_for_status()
        .context("daemon state rejected")?;
    response.json().await.context("parse daemon state")
}

fn base_url(metadata: &crate::server::ServerMetadata) -> String {
    let scheme = if metadata.mode == "lan" || metadata.mode == "remote" {
        "https"
    } else {
        "http"
    };
    format!("{scheme}://{}:{}", metadata.host, metadata.port)
}

/// The single source of a pinned, TLS-configured reqwest client for lan/remote
/// mode — every HTTP call site in this file must go through this rather than
/// constructing its own `Client::new()`, or it would silently bypass pinning.
fn mesh_http_client(metadata: &crate::server::ServerMetadata) -> Result<Client> {
    if metadata.mode == "lan" || metadata.mode == "remote" {
        let fingerprint_str = metadata.tls_fingerprint.as_deref().ok_or_else(|| {
            anyhow::anyhow!(
                "no TLS fingerprint recorded for this {} server — refusing to connect unpinned",
                metadata.mode
            )
        })?;
        let fingerprint = crate::tls::decode_fingerprint(fingerprint_str)?;
        let tls_config = crate::tls::pinned_client_config(fingerprint);
        Client::builder()
            .use_preconfigured_tls(tls_config)
            .build()
            .context("build pinned TLS client")
    } else {
        Ok(Client::new())
    }
}

fn percentile(values: &[f64], percentile: f64) -> f64 {
    if values.is_empty() {
        return 0.0;
    }
    let index = ((values.len() as f64 * percentile).ceil() as usize)
        .saturating_sub(1)
        .min(values.len() - 1);
    values[index]
}

fn room_for_target(target: &str) -> String {
    if target.starts_with("session:") || target.starts_with("actor:") {
        format!("direct:{target}")
    } else {
        target.to_string()
    }
}

fn spawned_actor_id(kind: &str, task_id: Option<&str>) -> String {
    match task_id {
        Some(task_id) => format!("actor:{kind}:{task_id}"),
        None => format!("actor:{kind}"),
    }
}

#[cfg(test)]
mod tests {
    use serde_json::json;
    use tempfile::TempDir;

    use crate::auth;
    use crate::store::MeshStore;

    use super::{
        ask_status, create_room, default_capabilities, job_events, merge_capabilities,
        normalize_platform, resolve_actor_from, sanitize_remote_error_message, send_message,
        set_activity, set_availability, set_doing, DEFAULT_ACTOR,
    };

    #[test]
    fn sanitize_remote_error_message_strips_control_characters() {
        let hostile = "\x1b[31mFAKE\x07 prompt \x1b]52;c;ZXZpbA==\x07 injection";
        let sanitized = sanitize_remote_error_message(hostile);
        assert!(
            !sanitized.chars().any(|c| c.is_control()),
            "sanitized message still contains control characters: {sanitized:?}"
        );
        assert!(sanitized.contains("FAKE"));
        assert!(sanitized.contains("injection"));
    }

    #[test]
    fn sanitize_remote_error_message_truncates_long_input_with_marker() {
        let long_message = "a".repeat(500);
        let sanitized = sanitize_remote_error_message(&long_message);
        assert!(
            sanitized.len() <= 200 + "... (truncated)".len(),
            "sanitized message not bounded: {} chars",
            sanitized.len()
        );
        assert!(sanitized.ends_with("... (truncated)"));
        let content = sanitized.strip_suffix("... (truncated)").unwrap();
        assert_eq!(content.chars().count(), 200);
        assert!(content.chars().all(|c| c == 'a'));
    }

    #[test]
    fn sanitize_remote_error_message_leaves_short_clean_input_untouched() {
        let sanitized = sanitize_remote_error_message("token expired");
        assert_eq!(sanitized, "token expired");
    }

    #[test]
    fn sanitize_remote_error_message_combines_control_stripping_and_truncation() {
        // 300 chars of control-character noise interleaved with junk, well
        // over the 200-char cap once stripped down to visible characters.
        let hostile_and_long: String = "\x1b[31mFAKE\x07 "
            .chars()
            .chain("x".repeat(300).chars())
            .collect();
        let sanitized = sanitize_remote_error_message(&hostile_and_long);
        assert!(!sanitized.chars().any(|c| c.is_control()));
        assert!(sanitized.ends_with("... (truncated)"));
        assert!(sanitized.len() <= 200 + "... (truncated)".len());
    }

    #[test]
    fn base_url_uses_https_for_lan_and_remote_http_for_local() {
        let mut metadata = crate::server::ServerMetadata {
            mode: "lan".to_string(),
            host: "192.168.1.10".to_string(),
            port: 47321,
            hostname: "laptop".to_string(),
            mdns: "laptop.local".to_string(),
            lan_ips: vec![],
            local_token: String::new(),
            started_by: "unknown".to_string(),
            started_at: String::new(),
            tls_fingerprint: Some("abc".to_string()),
        };
        assert_eq!(super::base_url(&metadata), "https://192.168.1.10:47321");
        metadata.mode = "remote".to_string();
        assert_eq!(super::base_url(&metadata), "https://192.168.1.10:47321");
        metadata.mode = "local".to_string();
        assert_eq!(super::base_url(&metadata), "http://192.168.1.10:47321");
    }

    #[test]
    fn mesh_http_client_requires_a_fingerprint_for_lan_and_remote_modes() {
        let metadata = crate::server::ServerMetadata {
            mode: "lan".to_string(),
            host: "192.168.1.10".to_string(),
            port: 47321,
            hostname: "laptop".to_string(),
            mdns: "laptop.local".to_string(),
            lan_ips: vec![],
            local_token: String::new(),
            started_by: "unknown".to_string(),
            started_at: String::new(),
            tls_fingerprint: None,
        };
        let result = super::mesh_http_client(&metadata);
        assert!(
            result.is_err(),
            "a lan-mode client with no recorded fingerprint must refuse to build a client rather than silently falling back to unpinned TLS"
        );
    }

    #[test]
    fn remote_metadata_url_rejects_non_http_scheme() {
        let err = super::remote_metadata_from_url("ssh://example.com:47321").unwrap_err();
        assert!(err.to_string().contains("remote mesh URL must use http"));
    }

    #[test]
    fn remote_metadata_url_requires_explicit_port_and_root_url() {
        for url in [
            "http://example.com",
            "http://user@example.com:47321",
            "http://example.com:47321/path",
            "http://example.com:47321?token=abc",
            "http://example.com:47321#fragment",
        ] {
            let err = super::remote_metadata_from_url(url).unwrap_err();
            assert!(
                err.to_string()
                    .contains("remote mesh URL must be http://host:port"),
                "unexpected error for {url}: {err:#}"
            );
        }
    }

    #[test]
    fn job_events_require_local_project_credential() {
        let project = TempDir::new().unwrap();
        let unauth_home = TempDir::new().unwrap();

        let err = job_events(
            project.path().to_path_buf(),
            Some(unauth_home.path().to_path_buf()),
            0,
        )
        .unwrap_err();

        assert!(
            err.to_string()
                .contains("local project credential required"),
            "unexpected error: {err:#}"
        );
    }

    #[test]
    fn job_events_only_return_job_types_after_since() {
        let project = TempDir::new().unwrap();
        let home = TempDir::new().unwrap();
        auth::bootstrap(project.path(), Some(home.path().to_path_buf())).unwrap();
        let store = MeshStore::open(project.path()).unwrap();
        store
            .append_event(
                "job.queued",
                "jobs",
                "session:lead",
                None,
                json!({ "task_id": "one" }),
            )
            .unwrap();
        store
            .append_event(
                "message.sent",
                "direct:session:worker",
                "session:lead",
                Some("session:worker"),
                json!({ "text": "not a job" }),
            )
            .unwrap();
        store
            .append_event(
                "job.done",
                "jobs",
                "session:worker",
                None,
                json!({ "task_id": "two" }),
            )
            .unwrap();

        let events = job_events(
            project.path().to_path_buf(),
            Some(home.path().to_path_buf()),
            1,
        )
        .unwrap();

        assert_eq!(events.len(), 1);
        assert_eq!(events[0].event_type, "job.done");
        assert_eq!(events[0].payload["task_id"], "two");
    }

    #[tokio::test]
    async fn append_local_event_rejects_observer_project_credential() {
        let project = TempDir::new().unwrap();
        let home = TempDir::new().unwrap();
        write_project_config(project.path(), "Mesh Client");
        write_project_credential(home.path(), "observer.cred", "mesh-client", "observer");

        let err = send_message(
            project.path().to_path_buf(),
            Some(home.path().to_path_buf()),
            "session:worker".to_string(),
            "status?".to_string(),
            None,
        )
        .await
        .unwrap_err();

        assert_eq!(
            err.to_string(),
            "local mutating project credential required"
        );
        assert!(!project.path().join(".workbench/mesh/events.jsonl").exists());
    }

    #[tokio::test]
    async fn create_room_rejects_observer_project_credential() {
        let project = TempDir::new().unwrap();
        let home = TempDir::new().unwrap();
        write_project_config(project.path(), "Mesh Client");
        write_project_credential(home.path(), "observer.cred", "mesh-client", "observer");

        let err = create_room(
            project.path().to_path_buf(),
            Some(home.path().to_path_buf()),
            "room:design".to_string(),
            None,
        )
        .await
        .unwrap_err();

        assert_eq!(
            err.to_string(),
            "local mutating project credential required"
        );
        assert!(!project.path().join(".workbench/mesh/events.jsonl").exists());
        assert!(!project.path().join(".workbench/mesh/audit.jsonl").exists());
    }

    #[tokio::test]
    async fn append_local_event_allows_worker_project_credential() {
        let project = TempDir::new().unwrap();
        let home = TempDir::new().unwrap();
        write_project_config(project.path(), "Mesh Client");
        write_project_credential(home.path(), "worker.cred", "mesh-client", "worker");

        send_message(
            project.path().to_path_buf(),
            Some(home.path().to_path_buf()),
            "session:worker".to_string(),
            "status?".to_string(),
            None,
        )
        .await
        .unwrap();

        let events = MeshStore::open(project.path())
            .unwrap()
            .list_events_since(0)
            .unwrap();
        assert_eq!(events.len(), 1);
        assert_eq!(events[0].event_type, "message.sent");
    }

    #[test]
    fn resolve_actor_prefers_explicit_over_env_over_default() {
        assert_eq!(
            resolve_actor_from(Some("actor:generator-1"), Some("actor:from-env")),
            "actor:generator-1"
        );
        assert_eq!(
            resolve_actor_from(None, Some("actor:from-env")),
            "actor:from-env"
        );
        assert_eq!(resolve_actor_from(None, None), DEFAULT_ACTOR);
        // blank explicit/env values must not shadow the next fallback
        assert_eq!(
            resolve_actor_from(Some("  "), Some("actor:from-env")),
            "actor:from-env"
        );
        assert_eq!(resolve_actor_from(Some(""), Some("")), DEFAULT_ACTOR);
    }

    #[tokio::test]
    async fn send_message_with_explicit_actor_identifies_the_real_sender() {
        let project = TempDir::new().unwrap();
        let home = TempDir::new().unwrap();
        write_project_config(project.path(), "Mesh Client");
        write_project_credential(home.path(), "worker.cred", "mesh-client", "worker");

        send_message(
            project.path().to_path_buf(),
            Some(home.path().to_path_buf()),
            "room:demo".to_string(),
            "hello from generator-1".to_string(),
            Some("actor:generator-1".to_string()),
        )
        .await
        .unwrap();

        let events = MeshStore::open(project.path())
            .unwrap()
            .list_events_since(0)
            .unwrap();
        assert_eq!(events.len(), 1);
        assert_eq!(events[0].from, "actor:generator-1");
        assert_ne!(events[0].from, DEFAULT_ACTOR);
    }

    #[test]
    fn default_capabilities_are_platform_specific_and_exclusive() {
        let macos = default_capabilities("macos");
        let windows = default_capabilities("windows");
        let linux = default_capabilities("linux");

        // Only macOS can run the iOS Simulator - dispatch must never see it
        // offered by Windows or Linux sessions.
        assert!(macos.contains(&"ios-simulator".to_string()));
        assert!(!windows.contains(&"ios-simulator".to_string()));
        assert!(!linux.contains(&"ios-simulator".to_string()));

        assert!(windows.contains(&"windows-native".to_string()));
        assert!(linux.contains(&"linux-native".to_string()));
        assert!(default_capabilities("unknown").is_empty());
    }

    #[test]
    fn merge_capabilities_dedupes_and_sorts_without_dropping_platform_defaults() {
        let merged = merge_capabilities(
            "macos",
            vec![
                "gpu".to_string(),
                "ios-simulator".to_string(), // duplicate of a platform default
                "  ".to_string(),            // blank must be ignored
                "gpu".to_string(),           // duplicate extra
            ],
        );
        assert_eq!(
            merged,
            vec!["android-emulator", "gpu", "ios-simulator", "macos-native"]
        );
    }

    #[test]
    fn normalize_platform_maps_unknown_raw_values_to_unknown() {
        assert_eq!(normalize_platform("macos"), "macos");
        assert_eq!(normalize_platform("windows"), "windows");
        assert_eq!(normalize_platform("linux"), "linux");
        assert_eq!(normalize_platform("freebsd"), "unknown");
    }

    #[tokio::test]
    async fn doing_reports_platform_and_capabilities_in_payload() {
        let project = TempDir::new().unwrap();
        let home = TempDir::new().unwrap();
        write_project_config(project.path(), "Mesh Client");
        write_project_credential(home.path(), "worker.cred", "mesh-client", "worker");

        set_doing(
            project.path().to_path_buf(),
            Some(home.path().to_path_buf()),
            "reviewing PR".to_string(),
            Some("actor:reviewer".to_string()),
            Some("linux".to_string()),
            vec!["docker".to_string()],
            None,
            None,
        )
        .await
        .unwrap();

        let events = MeshStore::open(project.path())
            .unwrap()
            .list_events_since(0)
            .unwrap();
        assert_eq!(events.len(), 1);
        assert_eq!(events[0].payload["platform"], "linux");
        let caps = events[0].payload["capabilities"].as_array().unwrap();
        let caps: Vec<&str> = caps.iter().map(|v| v.as_str().unwrap()).collect();
        assert!(caps.contains(&"linux-native"));
        assert!(caps.contains(&"docker"));
        assert!(!caps.contains(&"ios-simulator"));
        // No flag and no env var → explicit "unknown", never absent.
        assert_eq!(events[0].payload["provider"], "unknown");
        assert_eq!(events[0].payload["model"], "unknown");
    }

    #[tokio::test]
    async fn doing_reports_provider_and_model_in_payload() {
        let project = TempDir::new().unwrap();
        let home = TempDir::new().unwrap();
        write_project_config(project.path(), "Mesh Client");
        write_project_credential(home.path(), "worker.cred", "mesh-client", "worker");

        set_doing(
            project.path().to_path_buf(),
            Some(home.path().to_path_buf()),
            "building the tailer".to_string(),
            Some("generator-1".to_string()),
            Some("linux".to_string()),
            vec![],
            Some("claude".to_string()),
            Some("sonnet".to_string()),
        )
        .await
        .unwrap();

        let events = MeshStore::open(project.path())
            .unwrap()
            .list_events_since(0)
            .unwrap();
        assert_eq!(events.len(), 1);
        assert_eq!(events[0].payload["provider"], "claude");
        assert_eq!(events[0].payload["model"], "sonnet");
    }

    #[test]
    fn identity_field_prefers_flag_then_env_then_unknown() {
        assert_eq!(
            super::resolve_identity_field(Some("codex".to_string()), "WB_TEST_NO_SUCH_ENV"),
            "codex"
        );
        assert_eq!(
            super::resolve_identity_field(Some("  ".to_string()), "WB_TEST_NO_SUCH_ENV"),
            "unknown"
        );
        assert_eq!(
            super::resolve_identity_field(None, "WB_TEST_NO_SUCH_ENV"),
            "unknown"
        );
    }

    fn write_project_config(project: &std::path::Path, name: &str) {
        std::fs::create_dir_all(project.join(".workbench")).unwrap();
        std::fs::write(
            project.join(".workbench/config.json"),
            format!(r#"{{"project":{{"name":"{name}"}}}}"#),
        )
        .unwrap();
    }

    fn write_project_credential(home: &std::path::Path, filename: &str, project: &str, role: &str) {
        let project_dir = home.join("mesh/projects");
        std::fs::create_dir_all(&project_dir).unwrap();
        std::fs::write(
            project_dir.join(filename),
            format!(
                r#"{{
  "project": "{project}",
  "role": "{role}",
  "token": "test-token"
}}"#
            ),
        )
        .unwrap();
    }

    #[tokio::test]
    async fn activity_with_ack_of_emits_message_read() {
        let project = TempDir::new().unwrap();
        let home = TempDir::new().unwrap();
        write_project_config(project.path(), "Mesh Client");
        write_project_credential(home.path(), "worker.cred", "mesh-client", "worker");

        let sent = MeshStore::open(project.path())
            .unwrap()
            .append_event(
                "message.sent",
                "repo:workbench",
                "session:lead",
                Some("session:worker"),
                json!({ "text": "hi" }),
            )
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

        let events = MeshStore::open(project.path())
            .unwrap()
            .list_events_since(0)
            .unwrap();
        let ack = events
            .iter()
            .find(|e| e.event_type == "message.read")
            .unwrap();
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

        let events = MeshStore::open(project.path())
            .unwrap()
            .list_events_since(0)
            .unwrap();
        assert_eq!(events[0].event_type, "presence.heartbeat");
        assert_eq!(events[0].payload["activity"], "typing");
    }

    #[tokio::test]
    async fn set_activity_rejects_unknown_state() {
        let project = TempDir::new().unwrap();
        let home = TempDir::new().unwrap();
        write_project_config(project.path(), "Mesh Client");
        write_project_credential(home.path(), "worker.cred", "mesh-client", "worker");

        let error = set_activity(
            project.path().to_path_buf(),
            Some(home.path().to_path_buf()),
            "sleeping".to_string(),
            Some("session:worker".to_string()),
            None,
        )
        .await
        .unwrap_err();
        assert!(error.to_string().contains("invalid activity state"));

        let events = MeshStore::open(project.path())
            .unwrap()
            .list_events_since(0)
            .unwrap();
        assert!(events.is_empty(), "rejected activity must not be posted");
    }

    #[tokio::test]
    async fn set_availability_accepts_dashboard_recognized_states() {
        let project = TempDir::new().unwrap();
        let home = TempDir::new().unwrap();
        write_project_config(project.path(), "Mesh Client");
        write_project_credential(home.path(), "worker.cred", "mesh-client", "worker");

        set_availability(
            project.path().to_path_buf(),
            Some(home.path().to_path_buf()),
            "busy".to_string(),
            None,
            Some("session:worker".to_string()),
            Some("linux".to_string()),
            vec![],
            None,
            None,
        )
        .await
        .unwrap();

        let events = MeshStore::open(project.path())
            .unwrap()
            .list_events_since(0)
            .unwrap();
        assert_eq!(events[0].payload["availability"], "busy");
    }

    #[tokio::test]
    async fn set_availability_rejects_unknown_state() {
        let project = TempDir::new().unwrap();
        let home = TempDir::new().unwrap();
        write_project_config(project.path(), "Mesh Client");
        write_project_credential(home.path(), "worker.cred", "mesh-client", "worker");

        let error = set_availability(
            project.path().to_path_buf(),
            Some(home.path().to_path_buf()),
            "vacationing".to_string(),
            None,
            Some("session:worker".to_string()),
            Some("linux".to_string()),
            vec![],
            None,
            None,
        )
        .await
        .unwrap_err();
        assert!(error.to_string().contains("invalid availability state"));

        let events = MeshStore::open(project.path())
            .unwrap()
            .list_events_since(0)
            .unwrap();
        assert!(
            events.is_empty(),
            "rejected availability must not be posted"
        );
    }

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
                tls_fingerprint: None,
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

    #[tokio::test]
    async fn send_ack_emits_message_delivered_with_ack_of() {
        let project = TempDir::new().unwrap();
        let home = TempDir::new().unwrap();
        write_project_config(project.path(), "Mesh Client");
        write_project_credential(home.path(), "worker.cred", "mesh-client", "worker");

        let sent = MeshStore::open(project.path())
            .unwrap()
            .append_event(
                "message.sent",
                "repo:workbench",
                "session:lead",
                Some("session:worker"),
                json!({ "text": "hi" }),
            )
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

        let events = MeshStore::open(project.path())
            .unwrap()
            .list_events_since(0)
            .unwrap();
        let ack = events
            .iter()
            .find(|e| e.event_type == "message.delivered")
            .unwrap();
        assert_eq!(ack.ack_of, Some(sent.seq));
    }

    #[tokio::test]
    async fn watch_posts_a_non_empty_text_payload() {
        // The dashboard's chat ingest (live.js) falls back to an empty
        // string when `message.sent` has no `text`, rendering a blank
        // bubble. Guard against regressing back to that.
        let project = TempDir::new().unwrap();
        let home = TempDir::new().unwrap();
        write_project_config(project.path(), "Mesh Client");
        write_project_credential(home.path(), "worker.cred", "mesh-client", "worker");

        super::watch_actor(
            project.path().to_path_buf(),
            Some(home.path().to_path_buf()),
            "actor:worker".to_string(),
            Some("actor:lead".to_string()),
        )
        .await
        .unwrap();

        let events = MeshStore::open(project.path())
            .unwrap()
            .list_events_since(0)
            .unwrap();
        assert_eq!(events.len(), 1);
        assert_eq!(events[0].event_type, "message.sent");
        let text = events[0]
            .payload
            .get("text")
            .and_then(serde_json::Value::as_str)
            .unwrap_or_default();
        assert!(
            !text.is_empty(),
            "watch's payload must carry a non-empty text field, got: {:?}",
            events[0].payload
        );
        assert!(text.contains("actor:worker"));
    }

    #[tokio::test]
    async fn unknown_actor_warning_fires_for_a_never_seen_target_and_send_still_succeeds() {
        let project = TempDir::new().unwrap();
        let home = TempDir::new().unwrap();
        write_project_config(project.path(), "Mesh Client");
        write_project_credential(home.path(), "worker.cred", "mesh-client", "worker");

        // `actor:brandnew` has never appeared in this mesh's event log.
        let result = super::send_message(
            project.path().to_path_buf(),
            Some(home.path().to_path_buf()),
            "actor:brandnew".to_string(),
            "hello".to_string(),
            Some("actor:lead".to_string()),
        )
        .await;

        // CORE REGRESSION GUARD: a warning about an unrecognized target must
        // never become a send failure. There is no actor-registration step
        // in this mesh, so the very first legitimate message to a brand-new
        // actor must always succeed.
        assert!(
            result.is_ok(),
            "send must succeed even for an unknown actor: {result:?}"
        );

        let events = MeshStore::open(project.path())
            .unwrap()
            .list_events_since(0)
            .unwrap();
        assert_eq!(events.len(), 1, "the event must still be appended");
        assert_eq!(events[0].to.as_deref(), Some("actor:brandnew"));
    }

    #[tokio::test]
    async fn unknown_actor_warning_does_not_fire_for_a_target_with_prior_history() {
        let project = TempDir::new().unwrap();
        let home = TempDir::new().unwrap();
        write_project_config(project.path(), "Mesh Client");
        write_project_credential(home.path(), "worker.cred", "mesh-client", "worker");

        // Give `actor:worker` prior history before we probe it.
        MeshStore::open(project.path())
            .unwrap()
            .append_event(
                "message.sent",
                "direct:actor:worker",
                "actor:worker",
                Some("actor:lead"),
                json!({ "text": "hi from worker" }),
            )
            .unwrap();

        let warning = super::unknown_actor_warning(
            project.path(),
            Some(home.path().to_path_buf()),
            "actor:worker",
        )
        .await;
        assert!(
            warning.is_none(),
            "a target with prior history must not produce a warning, got: {warning:?}"
        );

        // Sending to it must still succeed as always.
        let result = super::send_message(
            project.path().to_path_buf(),
            Some(home.path().to_path_buf()),
            "actor:worker".to_string(),
            "second message".to_string(),
            Some("actor:lead".to_string()),
        )
        .await;
        assert!(
            result.is_ok(),
            "send to a known actor must succeed: {result:?}"
        );
    }

    #[tokio::test]
    async fn unknown_actor_warning_reflects_history_prior_to_this_send_not_after() {
        // Regression guard for a subtle self-contamination bug: a naive
        // "check known_actors *after* posting" would always find `to`
        // "known", because the event just posted itself names `to` as its
        // addressee. The check must reflect history that existed *before*
        // this particular send.
        let project = TempDir::new().unwrap();
        let home = TempDir::new().unwrap();
        write_project_config(project.path(), "Mesh Client");
        write_project_credential(home.path(), "worker.cred", "mesh-client", "worker");

        let warning_before_first_send = super::unknown_actor_warning(
            project.path(),
            Some(home.path().to_path_buf()),
            "actor:brandnew",
        )
        .await;
        assert!(warning_before_first_send.is_some());

        super::send_message(
            project.path().to_path_buf(),
            Some(home.path().to_path_buf()),
            "actor:brandnew".to_string(),
            "hello".to_string(),
            Some("actor:lead".to_string()),
        )
        .await
        .unwrap();

        // A *second* send to the same actor now correctly finds prior
        // history (from the first send) and should not warn again.
        let warning_on_second_send = super::unknown_actor_warning(
            project.path(),
            Some(home.path().to_path_buf()),
            "actor:brandnew",
        )
        .await;
        assert!(
            warning_on_second_send.is_none(),
            "after one prior send, the actor must be recognized as known"
        );
    }

    #[tokio::test]
    async fn ask_status_unknown_actor_warning_fires_for_a_never_seen_target_and_ask_still_succeeds()
    {
        // `ask_status` gates on the same non-blocking "unknown actor" warning
        // pattern as `send_message`/`watch_actor`. Prove the warning fires for
        // a brand-new target, and that `ask_status` itself still succeeds and
        // posts the event regardless.
        let project = TempDir::new().unwrap();
        let home = TempDir::new().unwrap();
        write_project_config(project.path(), "Mesh Client");
        write_project_credential(home.path(), "worker.cred", "mesh-client", "worker");

        let warning = super::unknown_actor_warning(
            project.path(),
            Some(home.path().to_path_buf()),
            "actor:brandnew",
        )
        .await;
        assert!(
            warning.is_some(),
            "a never-seen target must produce a warning"
        );

        let result = ask_status(
            project.path().to_path_buf(),
            Some(home.path().to_path_buf()),
            "actor:brandnew".to_string(),
            "how's it going?".to_string(),
            Some("actor:lead".to_string()),
        )
        .await;
        assert!(
            result.is_ok(),
            "ask must succeed even for an unknown actor: {result:?}"
        );

        let events = MeshStore::open(project.path())
            .unwrap()
            .list_events_since(0)
            .unwrap();
        assert_eq!(events.len(), 1, "the event must still be appended");
        assert_eq!(events[0].event_type, "message.request_status");
        assert_eq!(events[0].to.as_deref(), Some("actor:brandnew"));
        assert_eq!(events[0].payload["question"], "how's it going?");
    }

    #[tokio::test]
    async fn ask_status_unknown_actor_warning_does_not_fire_for_a_target_with_prior_history() {
        let project = TempDir::new().unwrap();
        let home = TempDir::new().unwrap();
        write_project_config(project.path(), "Mesh Client");
        write_project_credential(home.path(), "worker.cred", "mesh-client", "worker");

        // Give `actor:worker` prior history before we probe it.
        MeshStore::open(project.path())
            .unwrap()
            .append_event(
                "message.sent",
                "direct:actor:worker",
                "actor:worker",
                Some("actor:lead"),
                json!({ "text": "hi from worker" }),
            )
            .unwrap();

        let warning = super::unknown_actor_warning(
            project.path(),
            Some(home.path().to_path_buf()),
            "actor:worker",
        )
        .await;
        assert!(
            warning.is_none(),
            "a target with prior history must not produce a warning, got: {warning:?}"
        );

        let result = ask_status(
            project.path().to_path_buf(),
            Some(home.path().to_path_buf()),
            "actor:worker".to_string(),
            "still on track?".to_string(),
            Some("actor:lead".to_string()),
        )
        .await;
        assert!(
            result.is_ok(),
            "ask to a known actor must succeed: {result:?}"
        );
    }

    async fn wait_for_metadata(project: &std::path::Path) -> crate::server::ServerMetadata {
        use tokio::time::{sleep, Duration};

        for _ in 0..50 {
            if crate::server::server_metadata_path(project).is_file() {
                return crate::server::read_server_metadata(project).unwrap();
            }
            sleep(Duration::from_millis(20)).await;
        }
        panic!("server metadata was not written");
    }

    #[tokio::test]
    async fn remote_mode_known_actors_reflects_server_state_over_http() {
        // The `mode == "remote"` branch of `known_actors` (hitting a real
        // daemon's `/api/state` over HTTP) had zero test coverage — every
        // other test in this file only exercises the local-store dispatch.
        // Spin up a real server and drive a client configured in remote mode
        // against it, proving `known_actors`/`unknown_actor_warning` compose
        // correctly with the HTTP round trip, not just the local store.
        //
        // This test used to fake "remote" mode by pointing it at a
        // `bind: "local"` (plain HTTP) server and completing the handshake
        // through `accept_remote_invite`. Task 7 makes `mode == "remote"`
        // always mean pinned HTTPS (`base_url`/`mesh_http_client`), which
        // breaks that setup on two independent counts: `bind: "local"` never
        // starts a TLS listener at all (only `bind: "lan"` does), and
        // `remote_metadata_from_url` has no way yet to attach a fingerprint
        // to the metadata it builds from a bare URL (that plumbing is Task
        // 9/10's job — an https-only `remote_metadata_from_url` plus a
        // `--fingerprint` flag through `accept_remote_invite`). So instead:
        // start a real `bind: "lan"` server, complete the invite-accept
        // handshake ourselves directly over a manually pinned TLS client
        // (proving the pinned round trip genuinely works end to end, rather
        // than faking "remote" over plain HTTP), and hand the join side a
        // `ServerMetadata` carrying the lan server's real fingerprint —
        // mirroring what `accept_remote_invite` will persist once Task 9/10
        // land. Seeding a synthetic credential file with a fake token (as
        // one might first reach for) does not work here: the real lan
        // server's device registry only recognizes tokens it itself issued
        // via `/api/invites/accept`, so the join side needs a real,
        // server-recognized credential, not just a locally well-formed one.
        use crate::server::{serve, ServeOptions};

        let project = TempDir::new().unwrap();
        let host_home = TempDir::new().unwrap();
        let join_project = TempDir::new().unwrap();
        let join_home = TempDir::new().unwrap();
        write_project_config(project.path(), "Mesh Remote Actors");
        write_project_config(join_project.path(), "Mesh Remote Actors");
        auth::bootstrap(project.path(), Some(host_home.path().to_path_buf())).unwrap();
        let invite = auth::create_invite(
            project.path(),
            Some(host_home.path().to_path_buf()),
            "worker",
            900,
            1,
        )
        .unwrap();

        let server = tokio::spawn(serve(ServeOptions {
            project_root: project.path().to_path_buf(),
            home: Some(host_home.path().to_path_buf()),
            bind: "lan".to_string(),
            port: 0,
            pid_file: None,
            started_by: None,
        }));
        let host_metadata = wait_for_metadata(project.path()).await;
        let fingerprint = crate::tls::decode_fingerprint(
            host_metadata
                .tls_fingerprint
                .as_deref()
                .expect("lan mode must record a TLS fingerprint"),
        )
        .unwrap();
        let pinned_client = reqwest::Client::builder()
            .use_preconfigured_tls(crate::tls::pinned_client_config(fingerprint))
            .build()
            .unwrap();

        // Both projects resolve to the same project id — `project_id_for`
        // keys off `.workbench/config.json`'s `project.name` field, not the
        // directory path, and both dirs were configured with the same name
        // above — so the join side can present it as `expected_project`
        // exactly as `accept_remote_invite` would.
        let project_id = auth::project_id_for(project.path()).unwrap();
        assert_eq!(
            project_id,
            auth::project_id_for(join_project.path()).unwrap()
        );

        // Complete the invite-accept handshake ourselves, over the real
        // pinned TLS connection — this is the same request
        // `accept_remote_invite` sends (see its `/api/invites/accept` call),
        // just constructed directly since that function can't yet supply a
        // fingerprint for an https:// remote (Task 9/10).
        let response = pinned_client
            .post(format!(
                "https://127.0.0.1:{}/api/invites/accept",
                host_metadata.port
            ))
            .json(&json!({
                "token": invite.token,
                "device": "laptop",
                "expected_project": project_id,
            }))
            .send()
            .await
            .unwrap();
        assert!(
            response.status().is_success(),
            "invite accept over pinned TLS must succeed: {:?}",
            response.status()
        );
        let credential: auth::ProjectCredential = response.json().await.unwrap();
        assert_eq!(credential.project, project_id);
        auth::persist_project_credential(
            Some(join_home.path().to_path_buf()),
            "laptop",
            &credential,
        )
        .unwrap();

        // Hand the join side a "remote" metadata carrying the lan server's
        // real fingerprint — mirroring what `accept_remote_invite` records
        // today (minus the fingerprint itself, which is Task 9/10's job to
        // thread through `remote_metadata_from_url`).
        crate::server::write_server_metadata(
            join_project.path(),
            &crate::server::ServerMetadata {
                mode: "remote".to_string(),
                host: "127.0.0.1".to_string(),
                port: host_metadata.port,
                hostname: "127.0.0.1".to_string(),
                mdns: String::new(),
                lan_ips: vec![],
                local_token: String::new(),
                started_by: "unknown".to_string(),
                started_at: String::new(),
                tls_fingerprint: host_metadata.tls_fingerprint.clone(),
            },
        )
        .unwrap();

        // Before any traffic to a brand-new actor, the remote `/api/state`
        // round trip must not report it as known.
        let actors_before =
            super::known_actors(join_project.path(), Some(join_home.path().to_path_buf()))
                .await
                .unwrap();
        assert!(
            !actors_before.contains("actor:brandnew"),
            "actor must not be known before any traffic: {actors_before:?}"
        );

        let warning_before = super::unknown_actor_warning(
            join_project.path(),
            Some(join_home.path().to_path_buf()),
            "actor:brandnew",
        )
        .await;
        assert!(
            warning_before.is_some(),
            "warning must fire for a never-seen actor even over the remote branch"
        );

        // Post to the brand-new actor from the join side; this itself goes
        // over HTTP via `append_or_post_event`'s remote branch.
        super::send_message(
            join_project.path().to_path_buf(),
            Some(join_home.path().to_path_buf()),
            "actor:brandnew".to_string(),
            "hi".to_string(),
            None,
        )
        .await
        .unwrap();

        // Re-check: the remote branch must reflect server-side state after a
        // real round trip, not a stale/cached view.
        let actors_after =
            super::known_actors(join_project.path(), Some(join_home.path().to_path_buf()))
                .await
                .unwrap();
        assert!(
            actors_after.contains("actor:brandnew"),
            "actor must be known after a real send round-tripped through the server: {actors_after:?}"
        );

        let warning_after = super::unknown_actor_warning(
            join_project.path(),
            Some(join_home.path().to_path_buf()),
            "actor:brandnew",
        )
        .await;
        assert!(
            warning_after.is_none(),
            "warning must not fire once the server reflects the actor's history"
        );

        server.abort();
    }
}
