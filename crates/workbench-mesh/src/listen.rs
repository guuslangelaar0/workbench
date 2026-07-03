use std::path::{Path, PathBuf};

use anyhow::{Context, Result};
use futures_util::{SinkExt, StreamExt};
use serde_json::{json, Value};
use tokio_tungstenite::tungstenite::Message;

use crate::server::{read_server_metadata, ServerMetadata};

/// A single inbound message the connector acked and surfaced — the same
/// shape `mesh-inbox-wait.sh` prints today, kept stable so the harness-facing
/// wrapper doesn't need to change its parsing.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct InboxHit {
    pub seq: u64,
    pub room: String,
    pub from: String,
    pub text: String,
}

fn ws_url(metadata: &ServerMetadata, token: &str) -> String {
    format!(
        "ws://{}:{}/ws?token={token}&last_seq=0",
        metadata.host, metadata.port
    )
}

fn is_inbound_for(actor: &str, event: &Value) -> bool {
    let event_type = event.get("type").and_then(Value::as_str).unwrap_or("");
    if !(event_type.starts_with("message.") || event_type == "task.handoff") {
        return false;
    }
    if event.get("from").and_then(Value::as_str) == Some(actor) {
        return false; // never ack our own echo
    }
    let to_match = event.get("to").and_then(Value::as_str) == Some(actor);
    let room_match = event.get("room").and_then(Value::as_str) == Some(actor)
        || event
            .get("room")
            .and_then(Value::as_str)
            .map(|r| r == "team" || r.starts_with("repo:"))
            .unwrap_or(false);
    to_match || room_match
}

fn extract_text(event: &Value) -> String {
    let payload = event.get("payload").cloned().unwrap_or(json!({}));
    payload
        .get("text")
        .or_else(|| payload.get("question"))
        .or_else(|| payload.get("task_id"))
        .and_then(Value::as_str)
        .unwrap_or("?")
        .to_string()
}

/// First retry is fast (covers the common case — a blip); subsequent
/// retries back off exponentially, capped, with jitter so many actors
/// reconnecting after a server restart don't all hammer it in lockstep.
fn backoff_delay(attempt: u32) -> std::time::Duration {
    if attempt == 0 {
        return std::time::Duration::from_millis(250);
    }
    let base_ms = 250u64.saturating_mul(1u64 << attempt.min(6));
    let capped_ms = base_ms.min(5_000);
    // Jitter is at most 10% of the cap so the total never exceeds 5 500 ms.
    let jitter_ms = (capped_ms / 10).max(1);
    let jitter = (attempt as u64 * 97) % jitter_ms; // deterministic pseudo-jitter, no rand dependency needed
    std::time::Duration::from_millis(capped_ms + jitter)
}

/// Reconnect loop around `run_once`: every dropped connection is retried
/// with backoff rather than exiting, so a `listen` process started once at
/// session start survives server restarts for the rest of the dev session.
pub async fn run(project_root: PathBuf, home: Option<PathBuf>, actor: String) -> Result<()> {
    let mut attempt = 0u32;
    loop {
        match run_once(&project_root, home.clone(), &actor).await {
            Ok(()) => {
                eprintln!("listen: connection closed cleanly, reconnecting");
                attempt = 0;
            }
            Err(err) => {
                eprintln!("listen: connection error: {err:#}, reconnecting");
                attempt = attempt.saturating_add(1);
            }
        }
        tokio::time::sleep(backoff_delay(attempt)).await;
    }
}

/// Connects once, subscribes to the actor's own channel plus its
/// coordination rooms, and for every inbound event: acks it immediately
/// (`message.delivered`) and writes it to the actor's FIFO so the
/// harness-facing blocking reader wakes instantly instead of polling.
/// Returns when the connection drops — `run` wraps this in a reconnect loop.
pub async fn run_once(project_root: &Path, home: Option<PathBuf>, actor: &str) -> Result<()> {
    let metadata = read_server_metadata(project_root).context("read server metadata")?;
    let token = crate::auth::local_mutating_project_token(project_root, home)
        .context("resolve mutating token")?;
    let url = ws_url(&metadata, &token);
    let (ws_stream, _) = tokio_tungstenite::connect_async(&url)
        .await
        .with_context(|| format!("connect to {url}"))?;
    let (mut write, mut read) = ws_stream.split();

    let subscribe = json!({
        "v": 1,
        "type": "subscribe",
        "rooms": ["team", format!("repo:{}", project_slug(project_root)), actor],
        "actor": actor,
    });
    write
        .send(Message::Text(subscribe.to_string()))
        .await
        .context("send subscribe frame")?;

    #[cfg(unix)]
    let fifo_path = ensure_fifo(project_root, actor)?;
    #[cfg(not(unix))]
    eprintln!("listen: FIFO wake unsupported on this platform, falling back to no wake pipe");

    let mut ping_interval = tokio::time::interval(std::time::Duration::from_secs(5));
    let mut last_ping_sent: Option<tokio::time::Instant> = None;

    loop {
        tokio::select! {
            _ = ping_interval.tick() => {
                last_ping_sent = Some(tokio::time::Instant::now());
                if write.send(Message::Ping(vec![])).await.is_err() {
                    break;
                }
            }
            message = read.next() => {
                let Some(message) = message else { break };
                let message = message.context("read ws frame")?;
                match message {
                    Message::Pong(_) => {
                        if let Some(sent) = last_ping_sent.take() {
                            eprintln!("listen: rtt={}ms", sent.elapsed().as_millis());
                        }
                    }
                    Message::Text(text) => {
                        let Ok(envelope) = serde_json::from_str::<Value>(&text) else {
                            continue;
                        };
                        let events: Vec<Value> =
                            if envelope.get("type") == Some(&Value::String("batch".to_string())) {
                                envelope
                                    .get("events")
                                    .and_then(Value::as_array)
                                    .cloned()
                                    .unwrap_or_default()
                            } else {
                                vec![envelope]
                            };
                        for event in events {
                            if !is_inbound_for(actor, &event) {
                                continue;
                            }
                            let Some(seq) = event.get("seq").and_then(Value::as_u64) else {
                                continue;
                            };
                            let room = event
                                .get("room")
                                .and_then(Value::as_str)
                                .unwrap_or("")
                                .to_string();
                            let from = event
                                .get("from")
                                .and_then(Value::as_str)
                                .unwrap_or("")
                                .to_string();
                            let text = extract_text(&event);

                            let ack = json!({
                                "v": 1,
                                "type": "message.delivered",
                                "room": room,
                                "from": actor,
                                "ack_of": seq,
                                "payload": {},
                            });
                            if let Err(err) = write.send(Message::Text(ack.to_string())).await {
                                eprintln!("listen: failed to send ack for seq {seq}: {err}");
                            }

                            let hit = InboxHit { seq, room, from, text };
                            #[cfg(unix)]
                            if let Err(err) = write_fifo(&fifo_path, &hit) {
                                eprintln!("listen: failed to write inbox pipe: {err:#}");
                            }
                            #[cfg(not(unix))]
                            let _ = hit;
                        }
                    }
                    _ => {}
                }
            }
        }
    }
    Ok(())
}

fn project_slug(project_root: &Path) -> String {
    project_root
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("workbench")
        .to_string()
}

#[cfg(unix)]
fn ensure_fifo(project_root: &Path, actor: &str) -> Result<PathBuf> {
    let dir = project_root.join(".workbench/mesh");
    std::fs::create_dir_all(&dir).with_context(|| format!("create {}", dir.display()))?;
    let safe_actor = actor.replace([':', '/'], "-");
    let path = dir.join(format!("inbox-{safe_actor}.fifo"));
    if !path.exists() {
        let cpath = std::ffi::CString::new(path.to_string_lossy().as_bytes())
            .context("fifo path contains a NUL byte")?;
        // SAFETY: mkfifo is a standard POSIX syscall with a well-known, stable
        // signature. We pass a valid NUL-terminated C string and a plain mode
        // bitmask; no invariants beyond that are required.
        let result = unsafe { libc_mkfifo(cpath.as_ptr(), 0o600) };
        if result != 0 {
            anyhow::bail!(
                "mkfifo({}) failed: {}",
                path.display(),
                std::io::Error::last_os_error()
            );
        }
    }
    Ok(path)
}

// Raw FFI binding for the POSIX `mkfifo(2)` syscall.
// Using a local `extern "C"` block avoids adding a new `libc` / `nix`
// crate dependency for what is a single, stable system call.  If `libc` is
// ever added to the workspace for other reasons, replace this block with a
// direct call to `libc::mkfifo` and remove the declaration.
//
// `mode_t` width is platform-specific: u16 on macOS, u32 on Linux and other
// POSIX systems.  The alias ensures the FFI signature matches each target.
#[cfg(target_os = "macos")]
type ModeT = u16;
#[cfg(all(unix, not(target_os = "macos")))]
type ModeT = u32;

#[cfg(unix)]
extern "C" {
    #[link_name = "mkfifo"]
    fn libc_mkfifo(path: *const std::os::raw::c_char, mode: ModeT) -> i32;
}

/// Write a single inbox-hit line to the actor's FIFO.
///
/// Opening a FIFO for write blocks until a reader is attached, so this work
/// is pushed onto a detached OS thread — that way one slow or absent reader
/// never stalls the connector's main event loop (which must keep acking other
/// messages).  If no reader ever attaches, the thread parks indefinitely but
/// is harmless (no acks are delayed).
#[cfg(unix)]
fn write_fifo(path: &Path, hit: &InboxHit) -> Result<()> {
    use std::io::Write;
    let path = path.to_path_buf();
    let line = format!(
        "seq={} room={} from={}: {}\n",
        hit.seq, hit.room, hit.from, hit.text
    );
    std::thread::spawn(move || {
        if let Ok(mut file) = std::fs::OpenOptions::new().write(true).open(&path) {
            let _ = file.write_all(line.as_bytes());
        }
    });
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn is_inbound_for_matches_direct_and_room_targets_but_not_self() {
        let direct = json!({
            "type": "message.sent",
            "from": "session:lead",
            "to": "session:worker",
            "room": "direct:session:worker",
        });
        assert!(is_inbound_for("session:worker", &direct));

        let room = json!({
            "type": "message.sent",
            "from": "session:lead",
            "room": "repo:workbench",
        });
        assert!(is_inbound_for("session:worker", &room));

        let echo = json!({
            "type": "message.sent",
            "from": "session:worker",
            "to": "session:lead",
            "room": "direct:session:lead",
        });
        assert!(!is_inbound_for("session:worker", &echo));

        let unrelated = json!({
            "type": "presence.heartbeat",
            "from": "session:lead",
            "room": "presence",
        });
        assert!(!is_inbound_for("session:worker", &unrelated));
    }

    #[test]
    fn extract_text_prefers_text_then_question_then_task_id() {
        assert_eq!(extract_text(&json!({ "payload": { "text": "hi" } })), "hi");
        assert_eq!(
            extract_text(&json!({ "payload": { "question": "status?" } })),
            "status?"
        );
        assert_eq!(
            extract_text(&json!({ "payload": { "task_id": "wb-1" } })),
            "wb-1"
        );
        assert_eq!(extract_text(&json!({ "payload": {} })), "?");
    }

    #[test]
    fn backoff_delay_starts_fast_and_caps_at_five_seconds() {
        assert_eq!(
            super::backoff_delay(0),
            std::time::Duration::from_millis(250)
        );
        assert!(super::backoff_delay(1) > std::time::Duration::from_millis(250));
        assert!(
            super::backoff_delay(10)
                <= std::time::Duration::from_secs(5) + std::time::Duration::from_millis(500)
        );
        // every call must stay within a sane floor even with jitter
        assert!(super::backoff_delay(10) >= std::time::Duration::from_secs(2));
    }

    #[test]
    fn ws_url_targets_the_ws_endpoint_with_token_and_zero_last_seq() {
        let metadata = ServerMetadata {
            mode: "local".to_string(),
            host: "127.0.0.1".to_string(),
            port: 47321,
            hostname: "h".to_string(),
            mdns: "h.local".to_string(),
            lan_ips: vec![],
            local_token: "tok".to_string(),
            started_by: "unknown".to_string(),
            started_at: String::new(),
        };
        assert_eq!(
            ws_url(&metadata, "tok"),
            "ws://127.0.0.1:47321/ws?token=tok&last_seq=0"
        );
    }
}
