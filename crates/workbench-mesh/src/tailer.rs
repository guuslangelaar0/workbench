//! Output tailer — turns a session's structured CLI stream into mesh
//! `output.chunk` events.
//!
//! The parser extracts tool-call and assistant-message *boundaries* (never
//! raw token deltas, never full tool results) from the line-oriented JSON
//! that `claude -p --output-format stream-json --verbose` and
//! `codex exec --json` emit. Each boundary becomes one skimmable,
//! human-readable summary line for the per-agent `output:<actor>` room.

use serde_json::Value;

/// One human-facing feed line extracted from a stream event.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Chunk {
    /// "tool_call" or "message" — mirrors the dashboard's `payload.kind`.
    pub kind: &'static str,
    /// Tool name for tool_call chunks (e.g. "Bash", "Edit").
    pub tool: Option<String>,
    /// One line, truncated — a summary, not the raw input/output, so large
    /// diffs and secrets don't leak into the shared event log by default.
    pub summary: String,
}

const MAX_SUMMARY: usize = 160;

/// First non-empty line, truncated to MAX_SUMMARY chars (char-safe).
fn summarize(text: &str) -> String {
    let line = text
        .lines()
        .map(str::trim)
        .find(|l| !l.is_empty())
        .unwrap_or("");
    let mut out: String = line.chars().take(MAX_SUMMARY).collect();
    if line.chars().count() > MAX_SUMMARY {
        out.push('…');
    }
    out
}

/// Summarize a tool_use input by its most human-meaningful field rather
/// than dumping the whole argument object.
fn tool_summary(name: &str, input: &Value) -> String {
    let field = |key: &str| input.get(key).and_then(Value::as_str).map(summarize);
    let picked = match name {
        "Bash" => field("command"),
        "Edit" | "Write" | "Read" | "NotebookEdit" => field("file_path"),
        "Grep" | "Glob" => field("pattern"),
        "WebFetch" | "WebSearch" => field("url").or_else(|| field("query")),
        "Task" | "Agent" => field("description"),
        "Skill" => field("skill"),
        _ => None,
    };
    picked
        .or_else(|| field("command"))
        .or_else(|| field("file_path"))
        .or_else(|| field("description"))
        .unwrap_or_default()
}

/// Parse one stream line into zero or more chunks. Non-JSON lines, unknown
/// event shapes, tool results, and token deltas all yield nothing — the
/// tailer must never break a pipeline over content it doesn't understand.
pub fn extract_chunks(line: &str) -> Vec<Chunk> {
    let Ok(value) = serde_json::from_str::<Value>(line) else {
        return Vec::new();
    };
    let mut chunks = Vec::new();

    match value.get("type").and_then(Value::as_str) {
        // Claude Code stream-json: assistant turns carry text + tool_use blocks.
        Some("assistant") => {
            let content = value
                .get("message")
                .and_then(|m| m.get("content"))
                .and_then(Value::as_array);
            for block in content.into_iter().flatten() {
                match block.get("type").and_then(Value::as_str) {
                    Some("tool_use") => {
                        let name = block
                            .get("name")
                            .and_then(Value::as_str)
                            .unwrap_or("tool")
                            .to_string();
                        let summary =
                            tool_summary(&name, block.get("input").unwrap_or(&Value::Null));
                        chunks.push(Chunk {
                            kind: "tool_call",
                            summary: if summary.is_empty() {
                                name.clone()
                            } else {
                                summary
                            },
                            tool: Some(name),
                        });
                    }
                    Some("text") => {
                        let text = block.get("text").and_then(Value::as_str).unwrap_or("");
                        let summary = summarize(text);
                        if !summary.is_empty() {
                            chunks.push(Chunk {
                                kind: "message",
                                tool: None,
                                summary,
                            });
                        }
                    }
                    _ => {}
                }
            }
        }
        // Claude Code final result line.
        Some("result") => {
            let text = value.get("result").and_then(Value::as_str).unwrap_or("");
            let summary = summarize(text);
            if !summary.is_empty() {
                chunks.push(Chunk {
                    kind: "message",
                    tool: None,
                    summary: format!("result: {summary}"),
                });
            }
        }
        // Codex exec --json: completed items carry the boundary we want.
        Some("item.completed") => {
            if let Some(item) = value.get("item") {
                match item.get("type").and_then(Value::as_str) {
                    Some("command_execution") => {
                        let cmd = item.get("command").and_then(Value::as_str).unwrap_or("");
                        chunks.push(Chunk {
                            kind: "tool_call",
                            tool: Some("Bash".to_string()),
                            summary: summarize(cmd),
                        });
                    }
                    Some("file_change") => {
                        let path = item
                            .get("changes")
                            .and_then(Value::as_array)
                            .and_then(|c| c.first())
                            .and_then(|c| c.get("path"))
                            .and_then(Value::as_str)
                            .unwrap_or("file change");
                        chunks.push(Chunk {
                            kind: "tool_call",
                            tool: Some("Edit".to_string()),
                            summary: summarize(path),
                        });
                    }
                    Some("agent_message") => {
                        let text = item.get("text").and_then(Value::as_str).unwrap_or("");
                        let summary = summarize(text);
                        if !summary.is_empty() {
                            chunks.push(Chunk {
                                kind: "message",
                                tool: None,
                                summary,
                            });
                        }
                    }
                    // reasoning, todo_list, mcp_tool_call without mapping — skip.
                    _ => {}
                }
            }
        }
        // system/init, user/tool_result, stream deltas, unknown — skip.
        _ => {}
    }

    chunks
}

#[cfg(test)]
mod tests {
    use super::{extract_chunks, Chunk};

    #[test]
    fn claude_tool_use_becomes_tool_call_chunk() {
        let line = r#"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"cargo test -p wb-tailer","description":"Run tests"}}]}}"#;
        assert_eq!(
            extract_chunks(line),
            vec![Chunk {
                kind: "tool_call",
                tool: Some("Bash".to_string()),
                summary: "cargo test -p wb-tailer".to_string(),
            }]
        );
    }

    #[test]
    fn claude_edit_summarizes_by_file_path_not_full_diff() {
        let line = r#"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"src/boundary.rs","old_string":"SECRET_TOKEN=abc","new_string":"SECRET_TOKEN=def"}}]}}"#;
        let chunks = extract_chunks(line);
        assert_eq!(chunks.len(), 1);
        assert_eq!(chunks[0].summary, "src/boundary.rs");
        assert!(!chunks[0].summary.contains("SECRET_TOKEN"));
    }

    #[test]
    fn claude_assistant_text_becomes_message_chunk() {
        let line = r#"{"type":"assistant","message":{"content":[{"type":"text","text":"Tests pass.\nNow committing."}]}}"#;
        assert_eq!(
            extract_chunks(line),
            vec![Chunk {
                kind: "message",
                tool: None,
                summary: "Tests pass.".to_string(),
            }]
        );
    }

    #[test]
    fn mixed_content_yields_multiple_chunks_in_order() {
        let line = r#"{"type":"assistant","message":{"content":[{"type":"text","text":"Running tests."},{"type":"tool_use","name":"Bash","input":{"command":"cargo test"}}]}}"#;
        let chunks = extract_chunks(line);
        assert_eq!(chunks.len(), 2);
        assert_eq!(chunks[0].kind, "message");
        assert_eq!(chunks[1].kind, "tool_call");
    }

    #[test]
    fn result_line_is_prefixed() {
        let line = r#"{"type":"result","subtype":"success","result":"All 34 tests pass."}"#;
        assert_eq!(
            extract_chunks(line)[0].summary,
            "result: All 34 tests pass."
        );
    }

    #[test]
    fn tool_results_and_deltas_are_dropped() {
        let ignored = [
            r#"{"type":"user","message":{"content":[{"type":"tool_result","content":"huge output"}]}}"#,
            r#"{"type":"system","subtype":"init","tools":[]}"#,
            r#"{"type":"stream_event","event":{"type":"content_block_delta"}}"#,
            "plain text, not json",
            "",
        ];
        for line in ignored {
            assert!(extract_chunks(line).is_empty(), "should ignore: {line}");
        }
    }

    #[test]
    fn codex_command_and_message_items_map() {
        let cmd = r#"{"type":"item.completed","item":{"type":"command_execution","command":"./stress.sh --rounds 200"}}"#;
        let msg = r#"{"type":"item.completed","item":{"type":"agent_message","text":"200/200 rounds, 0 panics"}}"#;
        assert_eq!(extract_chunks(cmd)[0].tool.as_deref(), Some("Bash"));
        assert_eq!(extract_chunks(msg)[0].kind, "message");
    }

    #[test]
    fn long_summaries_are_truncated_to_one_line() {
        let long = "x".repeat(500);
        let line = format!(
            r#"{{"type":"assistant","message":{{"content":[{{"type":"text","text":"{long}"}}]}}}}"#
        );
        let chunks = extract_chunks(&line);
        assert_eq!(chunks[0].summary.chars().count(), 161); // 160 + ellipsis
    }
}
