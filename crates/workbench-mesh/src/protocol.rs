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

#[cfg(test)]
mod tests {
    use super::{validate_event_type, ALLOWED_EVENT_TYPES};

    #[test]
    fn validates_known_event_types() {
        for event_type in ALLOWED_EVENT_TYPES {
            validate_event_type(event_type).unwrap();
        }
    }

    #[test]
    fn rejects_unknown_event_types() {
        let err = validate_event_type("not.valid").unwrap_err();
        assert_eq!(err.to_string(), "invalid event type: not.valid");
    }
}
