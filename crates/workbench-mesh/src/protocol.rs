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
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub ack_of: Option<u64>,
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

#[cfg(test)]
mod tests {
    use super::{validate_ack, validate_event_room, validate_event_type, ALLOWED_EVENT_TYPES, EventEnvelope};

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
            ack_of: None,
        }
    }
}
