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
    pub devices: Vec<String>,
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
    let mut devices = BTreeSet::new();
    let mut room_names = BTreeSet::new();
    let mut actor_purposes = BTreeMap::new();
    let mut availability_by_actor = BTreeMap::new();
    let mut doing_by_actor = BTreeMap::new();
    let mut latest_availability = None;
    let mut latest_doing = None;
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
                        let purpose = purpose.to_string();
                        actor_purposes.insert(actor.to_string(), purpose);
                    }
                }
            }
            "presence.heartbeat" => {
                if let Some(state) = event
                    .payload
                    .get("availability")
                    .and_then(|value| value.as_str())
                {
                    let state = state.to_string();
                    availability_by_actor.insert(event.from.clone(), state.clone());
                    latest_availability = Some(state);
                }
            }
            "actor.status" => {
                if let Some(step) = event
                    .payload
                    .get("current_step")
                    .and_then(|value| value.as_str())
                {
                    let step = step.to_string();
                    doing_by_actor.insert(event.from.clone(), step.clone());
                    latest_doing = Some(step);
                }
            }
            "lead.purpose_set" => {
                if let Some(purpose) = event
                    .payload
                    .get("purpose")
                    .and_then(|value| value.as_str())
                {
                    let purpose = purpose.to_string();
                    actor_purposes.insert(event.from.clone(), purpose);
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
            "device.connected" => {
                if let Some(device) = event.payload.get("device").and_then(|value| value.as_str()) {
                    devices.insert(device.to_string());
                } else if let Some(to) = &event.to {
                    devices.insert(to.trim_start_matches("device:").to_string());
                }
            }
            "device.revoked" => {
                if let Some(device) = event.payload.get("device").and_then(|value| value.as_str()) {
                    devices.remove(device);
                }
            }
            "presence.stale" | "actor.stale" => {
                stale.insert(event.from.clone());
                active.remove(&event.from);
            }
            _ => {}
        }
    }

    let (current_actor_id, current_actor) = room_names
        .iter()
        .find_map(|name| actor_identity_from_room(name))
        .unwrap_or_else(|| ("session:lead".to_string(), "session:lead".to_string()));
    let purpose = actor_purposes.get(&current_actor_id).cloned();
    let availability = availability_by_actor
        .get(&current_actor_id)
        .cloned()
        .or(latest_availability)
        .unwrap_or_else(|| "available".to_string());
    let doing = doing_by_actor
        .get(&current_actor_id)
        .cloned()
        .or(latest_doing);

    StatuslineSnapshot {
        project: project.to_string(),
        current_actor,
        purpose,
        availability,
        doing,
        active_count: active.len(),
        stale_count: stale.len(),
        watched: watched.into_iter().collect(),
        devices: devices.into_iter().collect(),
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
    let devices = if snapshot.devices.is_empty() {
        String::new()
    } else {
        format!(" | devices {}", snapshot.devices.join(", "))
    };
    format!(
        "workbench | {} | {} | team {} active, {} stale{}",
        snapshot.current_actor, activity, snapshot.active_count, snapshot.stale_count, devices
    )
}

fn collect_live_actor(active: &mut BTreeSet<String>, stale: &mut BTreeSet<String>, value: &str) {
    if value.starts_with("session:") || value.starts_with("actor:") {
        active.insert(value.to_string());
        stale.remove(value);
    }
}

fn actor_identity_from_room(name: &str) -> Option<(String, String)> {
    let (role, focus) = name.split_once(':')?;
    if role.is_empty() || focus.is_empty() {
        return None;
    }
    Some((format!("session:{role}"), format!("{focus} {role}")))
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

    #[test]
    fn status_fields_prefer_current_actor_over_later_actor_events() {
        let events = vec![
            event(
                1,
                "room.created",
                "session:lead",
                None,
                json!({ "name": "lead:checkout" }),
            ),
            event(
                2,
                "lead.purpose_set",
                "session:lead",
                None,
                json!({ "purpose": "coordinate checkout" }),
            ),
            event(
                3,
                "presence.heartbeat",
                "session:lead",
                None,
                json!({ "availability": "busy" }),
            ),
            event(
                4,
                "actor.status",
                "session:lead",
                None,
                json!({ "current_step": "running checkout retry tests" }),
            ),
            event(
                5,
                "actor.spawned",
                "session:lead",
                Some("session:worker"),
                json!({
                    "actor": "session:worker",
                    "kind": "verifier",
                    "parent": "session:lead",
                    "purpose": "verify task 0042",
                    "task_id": "0042"
                }),
            ),
            event(
                6,
                "presence.heartbeat",
                "session:worker",
                None,
                json!({ "availability": "available" }),
            ),
            event(
                7,
                "actor.status",
                "session:worker",
                None,
                json!({ "current_step": "waiting for instructions" }),
            ),
        ];

        let snapshot = project_events_snapshot("meshops", &events);

        assert_eq!(snapshot.current_actor, "checkout lead");
        assert_eq!(snapshot.purpose.as_deref(), Some("coordinate checkout"));
        assert_eq!(snapshot.availability, "busy");
        assert_eq!(
            snapshot.doing.as_deref(),
            Some("running checkout retry tests")
        );
    }

    #[test]
    fn spawned_actor_purpose_does_not_become_current_actor_purpose() {
        let events = vec![
            event(
                1,
                "room.created",
                "session:lead",
                None,
                json!({ "name": "lead:checkout" }),
            ),
            event(
                2,
                "actor.spawned",
                "session:lead",
                Some("session:verifier"),
                json!({
                    "actor": "session:verifier",
                    "kind": "verifier",
                    "parent": "session:lead",
                    "purpose": "verify task 0042",
                    "task_id": "0042"
                }),
            ),
        ];

        let snapshot = project_events_snapshot("meshops", &events);

        assert_eq!(snapshot.current_actor, "checkout lead");
        assert_eq!(snapshot.purpose, None);
    }

    #[test]
    fn device_events_appear_in_snapshot_and_rendering() {
        let events = vec![
            event(
                1,
                "device.connected",
                "auth:invite",
                Some("device:macbook"),
                json!({ "device": "macbook", "role": "worker" }),
            ),
            event(
                2,
                "presence.heartbeat",
                "session:lead",
                None,
                json!({ "availability": "available" }),
            ),
        ];

        let snapshot = project_events_snapshot("meshops", &events);

        assert_eq!(snapshot.devices, vec!["macbook"]);
        assert!(super::render_compact(&snapshot).contains("devices macbook"));
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
