use std::path::PathBuf;
use std::time::Instant;

use anyhow::{Context, Result};
use reqwest::Client;
use serde_json::{json, Value};

use crate::auth;
use crate::server::read_server_metadata;

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
