use std::path::PathBuf;
use std::time::Instant;

use anyhow::{Context, Result};
use reqwest::Client;
use serde_json::{json, Value};

use crate::auth;
use crate::server::read_server_metadata;
use crate::statusline;
use crate::store::MeshStore;

const DEFAULT_ACTOR: &str = "session:lead";

pub async fn status(project_root: PathBuf, home: Option<PathBuf>) -> Result<()> {
    auth::require_local_project_credential(&project_root, home)?;
    let metadata = read_server_metadata(&project_root)?;
    let state = get_state(&metadata).await?;
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
    auth::require_local_project_credential(&project_root, home)?;
    let metadata = read_server_metadata(&project_root)?;
    let state = get_state(&metadata).await?;
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
    auth::require_local_project_credential(&project_root, home)?;
    let metadata = read_server_metadata(&project_root)?;
    let client = Client::new();
    let mut latencies = Vec::with_capacity(messages as usize);
    for idx in 0..messages {
        let started = Instant::now();
        client
            .post(format!("{}/api/events", base_url(&metadata)))
            .bearer_auth(&metadata.local_token)
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

pub fn create_room(project_root: PathBuf, home: Option<PathBuf>, name: String) -> Result<()> {
    let event = append_local_event(
        &project_root,
        home,
        "room.created",
        &name,
        DEFAULT_ACTOR,
        None,
        json!({ "name": name }),
    )?;
    println!("room: created {} seq={}", event.room, event.seq);
    Ok(())
}

pub fn send_message(
    project_root: PathBuf,
    home: Option<PathBuf>,
    to: String,
    text: String,
) -> Result<()> {
    let event = append_local_event(
        &project_root,
        home,
        "message.sent",
        &room_for_target(&to),
        DEFAULT_ACTOR,
        Some(&to),
        json!({ "text": text }),
    )?;
    println!("message: sent seq={}", event.seq);
    Ok(())
}

pub fn ask_status(
    project_root: PathBuf,
    home: Option<PathBuf>,
    to: String,
    question: String,
) -> Result<()> {
    let event = append_local_event(
        &project_root,
        home,
        "message.request_status",
        &room_for_target(&to),
        DEFAULT_ACTOR,
        Some(&to),
        json!({ "question": question }),
    )?;
    println!("ask: sent seq={}", event.seq);
    Ok(())
}

pub fn handoff_task(
    project_root: PathBuf,
    home: Option<PathBuf>,
    task_id: String,
    to: String,
) -> Result<()> {
    let event = append_local_event(
        &project_root,
        home,
        "task.handoff",
        "tasks",
        DEFAULT_ACTOR,
        Some(&to),
        json!({ "task_id": task_id }),
    )?;
    println!("handoff: sent seq={}", event.seq);
    Ok(())
}

pub fn set_availability(
    project_root: PathBuf,
    home: Option<PathBuf>,
    state: String,
    reason: Option<String>,
) -> Result<()> {
    let event = append_local_event(
        &project_root,
        home,
        "presence.heartbeat",
        "presence",
        DEFAULT_ACTOR,
        None,
        json!({ "availability": state, "reason": reason }),
    )?;
    println!("availability: updated seq={}", event.seq);
    Ok(())
}

pub fn set_doing(project_root: PathBuf, home: Option<PathBuf>, text: String) -> Result<()> {
    let event = append_local_event(
        &project_root,
        home,
        "actor.status",
        "presence",
        DEFAULT_ACTOR,
        None,
        json!({ "current_step": text }),
    )?;
    println!("doing: updated seq={}", event.seq);
    Ok(())
}

pub fn watch_actor(project_root: PathBuf, home: Option<PathBuf>, actor: String) -> Result<()> {
    let event = append_local_event(
        &project_root,
        home,
        "message.sent",
        &room_for_target(&actor),
        DEFAULT_ACTOR,
        Some(&actor),
        json!({ "intent": "watch", "actor": actor }),
    )?;
    println!("watch: added seq={}", event.seq);
    Ok(())
}

pub fn spawn_actor(
    project_root: PathBuf,
    home: Option<PathBuf>,
    kind: String,
    parent: String,
    purpose: String,
    task_id: Option<String>,
) -> Result<()> {
    let actor = spawned_actor_id(&kind, task_id.as_deref());
    let event = append_local_event(
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
    )?;
    println!("actor: spawned seq={}", event.seq);
    Ok(())
}

pub fn snapshot_statusline(project_root: PathBuf, home: Option<PathBuf>) -> Result<()> {
    auth::require_local_project_credential(&project_root, home.clone())?;
    let written = statusline::write_snapshot(&project_root, home)?;
    println!("{}", written.display());
    Ok(())
}

fn append_local_event(
    project_root: &std::path::Path,
    home: Option<PathBuf>,
    event_type: &str,
    room: &str,
    from: &str,
    to: Option<&str>,
    payload: Value,
) -> Result<crate::protocol::EventEnvelope> {
    auth::require_local_project_credential(project_root, home)?;
    MeshStore::open(project_root)?.append_event(event_type, room, from, to, payload)
}

async fn get_state(metadata: &crate::server::ServerMetadata) -> Result<Value> {
    let response = Client::new()
        .get(format!("{}/api/state", base_url(metadata)))
        .bearer_auth(&metadata.local_token)
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
