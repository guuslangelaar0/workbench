use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};

use crate::auth;
use crate::protocol::EventEnvelope;
use crate::store::MeshStore;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
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

pub fn write_snapshot(project_root: &Path, home: Option<PathBuf>) -> Result<PathBuf> {
    let auth_paths = auth::paths(home)?;
    let project = project_id(project_root)?;
    let snapshot = project_snapshot(project_root)?;
    let statusline_dir = auth_paths.home.join("mesh/statusline");
    fs::create_dir_all(&statusline_dir)
        .with_context(|| format!("create {}", statusline_dir.display()))?;
    let path = statusline_dir.join(format!("{project}.json"));
    let content = serde_json::to_string(&snapshot).context("serialize statusline snapshot")?;
    fs::write(&path, content).with_context(|| format!("write {}", path.display()))?;
    println!("{}", render_compact(&snapshot));
    Ok(path)
}

pub fn project_snapshot(project_root: &Path) -> Result<StatuslineSnapshot> {
    let project = project_id(project_root)?;
    let store = MeshStore::open(project_root)?;
    let events = store.list_events_since(0)?;
    Ok(project_events_snapshot(&project, &events))
}

pub fn project_events_snapshot(project: &str, events: &[EventEnvelope]) -> StatuslineSnapshot {
    let mut active = BTreeSet::new();
    let mut stale = BTreeSet::new();
    let mut watched = BTreeSet::new();
    let mut room_names = BTreeSet::new();
    let mut actor_purposes = BTreeMap::new();
    let mut availability = "available".to_string();
    let mut doing = None;
    let mut unread_mentions = 0;

    for event in events {
        collect_live_actor(&mut active, &mut stale, &event.from);
        if let Some(to) = &event.to {
            collect_live_actor(&mut active, &mut stale, to);
        }

        match event.event_type.as_str() {
            "room.created" => {
                if let Some(name) = event.payload.get("name").and_then(|value| value.as_str()) {
                    room_names.insert(name.to_string());
                }
            }
            "actor.spawned" => {
                if let Some(actor) = event.payload.get("actor").and_then(|value| value.as_str()) {
                    collect_live_actor(&mut active, &mut stale, actor);
                    if let Some(purpose) = event
                        .payload
                        .get("purpose")
                        .and_then(|value| value.as_str())
                    {
                        actor_purposes.insert(actor.to_string(), purpose.to_string());
                    }
                }
            }
            "presence.heartbeat" => {
                if let Some(state) = event
                    .payload
                    .get("availability")
                    .and_then(|value| value.as_str())
                {
                    availability = state.to_string();
                }
            }
            "actor.status" => {
                if let Some(step) = event
                    .payload
                    .get("current_step")
                    .and_then(|value| value.as_str())
                {
                    doing = Some(step.to_string());
                }
            }
            "message.sent" => {
                if event.payload.get("intent").and_then(|value| value.as_str()) == Some("watch") {
                    if let Some(actor) = event.payload.get("actor").and_then(|value| value.as_str())
                    {
                        watched.insert(actor.to_string());
                    } else if let Some(to) = &event.to {
                        watched.insert(to.to_string());
                    }
                }
            }
            "message.mention" => unread_mentions += 1,
            "presence.stale" | "actor.stale" => {
                stale.insert(event.from.clone());
                active.remove(&event.from);
            }
            _ => {}
        }
    }

    let current_actor = room_names
        .iter()
        .find_map(|name| actor_label_from_room(name))
        .unwrap_or_else(|| "session:lead".to_string());
    let purpose = actor_purposes.values().next().cloned();

    StatuslineSnapshot {
        project: project.to_string(),
        current_actor,
        purpose,
        availability,
        doing,
        active_count: active.len(),
        stale_count: stale.len(),
        watched: watched.into_iter().collect(),
        unread_mentions,
    }
}

pub fn render_compact(snapshot: &StatuslineSnapshot) -> String {
    let activity = match &snapshot.doing {
        Some(doing) if !doing.trim().is_empty() => {
            format!("{}: {}", snapshot.availability, doing)
        }
        _ => snapshot.availability.clone(),
    };
    format!(
        "workbench | {} | {} | team {} active, {} stale",
        snapshot.current_actor, activity, snapshot.active_count, snapshot.stale_count
    )
}

fn collect_live_actor(active: &mut BTreeSet<String>, stale: &mut BTreeSet<String>, value: &str) {
    if value.starts_with("session:") || value.starts_with("actor:") {
        active.insert(value.to_string());
        stale.remove(value);
    }
}

fn actor_label_from_room(name: &str) -> Option<String> {
    let (role, focus) = name.split_once(':')?;
    if role.is_empty() || focus.is_empty() {
        return None;
    }
    Some(format!("{focus} {role}"))
}

fn project_id(project_root: &Path) -> Result<String> {
    let config_path = project_root.join(".workbench/config.json");
    if config_path.is_file() {
        let config: serde_json::Value = serde_json::from_slice(
            &fs::read(&config_path).with_context(|| format!("read {}", config_path.display()))?,
        )
        .with_context(|| format!("parse {}", config_path.display()))?;
        if let Some(name) = config
            .get("project")
            .and_then(|project| project.get("name"))
            .and_then(|name| name.as_str())
        {
            return Ok(sanitize_name(name));
        }
    }

    let name = project_root
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("project");
    Ok(sanitize_name(name))
}

fn sanitize_name(value: &str) -> String {
    let mut sanitized = String::new();
    for ch in value.chars() {
        if ch.is_ascii_alphanumeric() {
            sanitized.push(ch.to_ascii_lowercase());
        } else if matches!(ch, '-' | '_') {
            sanitized.push(ch);
        } else if !sanitized.ends_with('-') {
            sanitized.push('-');
        }
    }
    let trimmed = sanitized.trim_matches('-');
    if trimmed.is_empty() {
        "project".to_string()
    } else {
        trimmed.to_string()
    }
}

#[cfg(test)]
mod tests {
    use serde_json::{json, Value};

    use crate::protocol::EventEnvelope;

    use super::project_events_snapshot;

    #[test]
    fn later_actor_activity_removes_actor_from_stale_set() {
        let events = vec![
            event(
                1,
                "actor.stale",
                "session:worker",
                None,
                json!({ "reason": "missed heartbeat" }),
            ),
            event(
                2,
                "presence.heartbeat",
                "session:worker",
                None,
                json!({ "availability": "available" }),
            ),
        ];

        let snapshot = project_events_snapshot("meshops", &events);

        assert_eq!(snapshot.active_count, 1);
        assert_eq!(snapshot.stale_count, 0);
    }

    fn event(
        seq: u64,
        event_type: &str,
        from: &str,
        to: Option<&str>,
        payload: Value,
    ) -> EventEnvelope {
        EventEnvelope {
            v: 1,
            id: format!("event-{seq}"),
            seq,
            event_type: event_type.to_string(),
            room: "presence".to_string(),
            from: from.to_string(),
            to: to.map(str::to_string),
            ts: "2026-01-01T00:00:00Z".to_string(),
            payload,
        }
    }
}
