use std::fs::{self, File, OpenOptions};
use std::io::{BufRead, BufReader, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};

use anyhow::{Context, Result};
use fs2::FileExt;
use serde_json::Value;
use time::format_description::well_known::Rfc3339;
use time::OffsetDateTime;
use uuid::Uuid;

use crate::protocol::{validate_event_type, EventEnvelope};

pub struct MeshStore {
    root: PathBuf,
}

impl MeshStore {
    pub fn open(project_root: impl Into<PathBuf>) -> Result<Self> {
        let root = project_root.into().join(".workbench/mesh");
        fs::create_dir_all(&root)
            .with_context(|| format!("create mesh dir at {}", root.display()))?;
        ensure_file(&root.join("events.jsonl"))?;
        ensure_file(&root.join("audit.jsonl"))?;
        Ok(Self { root })
    }

    pub fn append_event(
        &self,
        event_type: &str,
        room: &str,
        from: &str,
        to: Option<&str>,
        payload: Value,
    ) -> Result<EventEnvelope> {
        validate_event_type(event_type)?;
        let path = self.root.join("events.jsonl");
        append_locked_jsonl(&path, |seq| {
            Ok(EventEnvelope {
                v: 1,
                id: Uuid::now_v7().to_string(),
                seq,
                event_type: event_type.to_string(),
                room: room.to_string(),
                from: from.to_string(),
                to: to.map(str::to_string),
                ts: OffsetDateTime::now_utc()
                    .format(&Rfc3339)
                    .context("format event timestamp")?,
                payload,
            })
        })
    }

    pub fn list_events_since(&self, since: u64) -> Result<Vec<EventEnvelope>> {
        let path = self.root.join("events.jsonl");
        let file = File::open(&path)
            .with_context(|| format!("open event log {}", path.display()))?;
        let reader = BufReader::new(file);
        let mut events = Vec::new();

        for line in reader.lines() {
            let line = line.with_context(|| format!("read line from {}", path.display()))?;
            if line.trim().is_empty() {
                continue;
            }
            let event: EventEnvelope = serde_json::from_str(&line)
                .with_context(|| format!("parse event from {}", path.display()))?;
            if event.seq > since {
                events.push(event);
            }
        }

        Ok(events)
    }

    pub fn append_audit(&self, action: &str, actor: &str, payload: Value) -> Result<EventEnvelope> {
        validate_event_type(action)?;
        let path = self.root.join("audit.jsonl");
        append_locked_jsonl(&path, |seq| {
            Ok(EventEnvelope {
                v: 1,
                id: Uuid::now_v7().to_string(),
                seq,
                event_type: action.to_string(),
                room: "audit".to_string(),
                from: actor.to_string(),
                to: None,
                ts: OffsetDateTime::now_utc()
                    .format(&Rfc3339)
                    .context("format audit timestamp")?,
                payload,
            })
        })
    }
}

fn ensure_file(path: &Path) -> Result<()> {
    OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)
        .with_context(|| format!("open {}", path.display()))?;
    Ok(())
}

fn next_seq(file: &File, path: &Path) -> Result<u64> {
    let mut reader_file = file
        .try_clone()
        .with_context(|| format!("clone {}", path.display()))?;
    reader_file
        .seek(SeekFrom::Start(0))
        .with_context(|| format!("rewind {}", path.display()))?;
    let reader = BufReader::new(reader_file);
    let mut seq = 0;

    for line in reader.lines() {
        let line = line.with_context(|| format!("read line from {}", path.display()))?;
        if line.trim().is_empty() {
            continue;
        }
        let event: EventEnvelope =
            serde_json::from_str(&line).with_context(|| format!("parse {}", path.display()))?;
        seq = seq.max(event.seq);
    }

    Ok(seq + 1)
}

fn append_jsonl(file: &mut File, path: &Path, event: &EventEnvelope) -> Result<()> {
    serde_json::to_writer(&mut *file, event).context("serialize event")?;
    file.write_all(b"\n")
        .with_context(|| format!("write newline to {}", path.display()))?;
    file.flush()
        .with_context(|| format!("flush {}", path.display()))?;
    Ok(())
}

fn append_locked_jsonl(
    path: &Path,
    build_event: impl FnOnce(u64) -> Result<EventEnvelope>,
) -> Result<EventEnvelope> {
    let mut file = OpenOptions::new()
        .read(true)
        .append(true)
        .create(true)
        .open(path)
        .with_context(|| format!("open {} for locked append", path.display()))?;
    file.lock_exclusive()
        .with_context(|| format!("lock {}", path.display()))?;

    let result = (|| {
        let seq = next_seq(&file, path)?;
        let event = build_event(seq)?;
        append_jsonl(&mut file, path, &event)?;
        Ok(event)
    })();

    file.unlock()
        .with_context(|| format!("unlock {}", path.display()))?;

    result
}
#[cfg(test)]
mod tests {
    use std::collections::BTreeSet;
    use std::sync::{Arc, Barrier};
    use std::thread;

    use serde_json::json;
    use tempfile::TempDir;

    use super::MeshStore;

    #[test]
    fn appends_and_lists_events() {
        let temp = TempDir::new().unwrap();
        let store = MeshStore::open(temp.path()).unwrap();

        let first = store
            .append_event(
                "presence.join",
                "repo:test",
                "session:lead",
                None,
                json!({ "role": "lead" }),
            )
            .unwrap();
        let second = store
            .append_event(
                "message.sent",
                "repo:test",
                "session:lead",
                Some("session:peer"),
                json!({ "text": "status?" }),
            )
            .unwrap();

        assert_eq!(first.seq, 1);
        assert_eq!(second.seq, 2);

        let listed = store.list_events_since(1).unwrap();
        assert_eq!(listed, vec![second]);
    }

    #[test]
    fn creates_audit_log_on_open() {
        let temp = TempDir::new().unwrap();
        let store = MeshStore::open(temp.path()).unwrap();

        store
            .append_audit("invite.created", "session:lead", json!({ "uses": 1 }))
            .unwrap();

        assert!(temp.path().join(".workbench/mesh/events.jsonl").is_file());
        assert!(temp.path().join(".workbench/mesh/audit.jsonl").is_file());
    }

    #[test]
    fn concurrent_appenders_allocate_unique_contiguous_sequences() {
        let temp = TempDir::new().unwrap();
        let project_root = temp.path().to_path_buf();
        let writers = 24;
        let barrier = Arc::new(Barrier::new(writers));
        let mut handles = Vec::with_capacity(writers);

        for idx in 0..writers {
            let project_root = project_root.clone();
            let barrier = Arc::clone(&barrier);
            handles.push(thread::spawn(move || {
                let store = MeshStore::open(&project_root).unwrap();
                barrier.wait();
                store
                    .append_event(
                        "message.sent",
                        "repo:test",
                        &format!("session:{idx}"),
                        None,
                        json!({ "writer": idx }),
                    )
                    .unwrap()
                    .seq
            }));
        }

        let seqs: Vec<u64> = handles.into_iter().map(|handle| handle.join().unwrap()).collect();
        let unique: BTreeSet<u64> = seqs.iter().copied().collect();

        assert_eq!(unique.len(), writers, "duplicate sequences: {seqs:?}");
        assert_eq!(unique.into_iter().collect::<Vec<_>>(), (1..=writers as u64).collect::<Vec<_>>());
    }
}
