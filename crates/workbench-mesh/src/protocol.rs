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
    "presence.join",
    "presence.heartbeat",
    "presence.stale",
    "device.capabilities",
    "device.connected",
    "device.revoked",
    "device.auth_rejected",
    "room.created",
    "room.member_added",
    "message.sent",
    "message.delivered",
    "message.read",
    "message.reply",
    "message.mention",
    "message.request_status",
    "message.status_response",
    "message.help_request",
    "message.help_offer",
    "message.conflict_warning",
    "lead.purpose_set",
    "lead.closed",
    "lead.adopted",
    "actor.spawned",
    "actor.heartbeat",
    "actor.status",
    "actor.output",
    "output.chunk",
    "actor.done",
    "actor.failed",
    "actor.stale",
    "actor.cancelled",
    "task.claim",
    "task.handoff",
    "task.handoff.accepted",
    "task.status",
    "task.reassigned",
    "job.queued",
    "job.started",
    "job.output",
    "job.done",
    "job.failed",
    "job.cancelled",
    "decision.request",
    "decision.answer",
    "invite.created",
    "invite.accepted",
    "invite.exhausted",
    "invite.expired",
    "invite.revoked",
];

pub fn validate_event_type(event_type: &str) -> anyhow::Result<()> {
    if ALLOWED_EVENT_TYPES.contains(&event_type) {
        Ok(())
    } else {
        anyhow::bail!("invalid event type: {event_type}")
    }
}

/// Room-scoped rules on top of the type allowlist: `output.chunk` is the
/// per-agent live-output feed and must stay in its dedicated `output:<actor>`
/// room so it never mixes with coordination chat — and vice versa.
pub fn validate_event_room(event_type: &str, room: &str) -> anyhow::Result<()> {
    let is_output_room = room.starts_with("output:") && room.len() > "output:".len();
    if event_type == "output.chunk" && !is_output_room {
        anyhow::bail!("output.chunk events must target an output:<actor> room, got: {room}")
    }
    if event_type != "output.chunk" && is_output_room {
        anyhow::bail!("room {room} only accepts output.chunk events, got: {event_type}")
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::{validate_event_room, validate_event_type, ALLOWED_EVENT_TYPES};

    #[test]
    fn validates_known_event_types() {
        for event_type in ALLOWED_EVENT_TYPES {
            validate_event_type(event_type).unwrap();
        }
        validate_event_type("device.connected").unwrap();
        validate_event_type("device.revoked").unwrap();
        validate_event_type("device.auth_rejected").unwrap();
    }

    #[test]
    fn rejects_unknown_event_types() {
        let err = validate_event_type("not.valid").unwrap_err();
        assert_eq!(err.to_string(), "invalid event type: not.valid");
    }

    #[test]
    fn output_chunk_requires_output_room() {
        validate_event_room("output.chunk", "output:generator-1").unwrap();
        let err = validate_event_room("output.chunk", "repo:workbench").unwrap_err();
        assert!(err.to_string().contains("output:<actor>"));
        let err = validate_event_room("output.chunk", "output:").unwrap_err();
        assert!(err.to_string().contains("output:<actor>"));
    }

    #[test]
    fn output_rooms_reject_coordination_events() {
        let err = validate_event_room("message.sent", "output:generator-1").unwrap_err();
        assert!(err.to_string().contains("only accepts output.chunk"));
        validate_event_room("message.sent", "repo:workbench").unwrap();
    }
}
