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
                println!("{actor}");
            }
        }
    }
    Ok(())
}

pub async fn bench(project_root: PathBuf, home: Option<PathBuf>, messages: u64) -> Result<()> {
    let token = auth::local_mutating_project_token(&project_root, home)?;
    let metadata = read_server_metadata(&project_root)?;
    let client = Client::new();
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

pub async fn accept_remote_invite(
    project_root: PathBuf,
    home: Option<PathBuf>,
    url: String,
    token: String,
    device: String,
) -> Result<()> {
    let metadata = remote_metadata_from_url(&url)?;
    let local_project = auth::project_id_for(&project_root)?;
    let response = Client::new()
        .post(format!("{}/api/invites/accept", base_url(&metadata)))
        .json(&json!({
            "token": token,
            "device": device,
            "expected_project": local_project,
        }))
        .send()
        .await
        .context("post remote invite accept")?
        .error_for_status()
        .context("remote invite rejected")?;
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
    })
}

pub async fn list_devices(project_root: PathBuf, home: Option<PathBuf>) -> Result<()> {
    let token = auth::local_operator_project_token(&project_root, home)?;
    let metadata = read_server_metadata(&project_root)?;
    let body: Value = Client::new()
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
    Client::new()
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

pub async fn create_room(
    project_root: PathBuf,
    home: Option<PathBuf>,
    name: String,
    from: Option<String>,
) -> Result<()> {
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
    Ok(())
}

pub async fn send_message(
    project_root: PathBuf,
    home: Option<PathBuf>,
    to: String,
    text: String,
    from: Option<String>,
) -> Result<()> {
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
    Ok(())
}

pub async fn ask_status(
    project_root: PathBuf,
    home: Option<PathBuf>,
    to: String,
    question: String,
    from: Option<String>,
) -> Result<()> {
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

pub async fn watch_actor(
    project_root: PathBuf,
    home: Option<PathBuf>,
    actor: String,
    from: Option<String>,
) -> Result<()> {
    let event = append_or_post_event(
        &project_root,
        home,
        "message.sent",
        &room_for_target(&actor),
        &resolve_actor(from.as_deref()),
        Some(&actor),
        json!({ "intent": "watch", "actor": actor }),
    )
    .await?;
    println!("watch: added seq={}", event.seq);
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
            let response = Client::new()
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

async fn get_state(metadata: &crate::server::ServerMetadata, token: &str) -> Result<Value> {
    let response = Client::new()
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
    format!("http://{}:{}", metadata.host, metadata.port)
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
        default_capabilities, job_events, merge_capabilities, normalize_platform,
        resolve_actor_from, send_message, set_doing, DEFAULT_ACTOR,
    };

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
}
