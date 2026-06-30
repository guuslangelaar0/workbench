Status: DONE

Summary of changes
- Added a Rust workspace at the repo root and a new `workbench-mesh` crate.
- Implemented the public protocol surface in `workbench_mesh::protocol` with `EventEnvelope`, `ALLOWED_EVENT_TYPES`, and `validate_event_type`.
- Implemented append-only JSONL mesh storage in `store.rs` for `.workbench/mesh/events.jsonl` and `.workbench/mesh/audit.jsonl`.
- Implemented CLI support for `workbench-mesh event append` and `workbench-mesh event list`.
- Added the shell regression test `test/mesh-protocol.test.sh`.
- Updated `.gitignore` with `/target/` and `/.workbench/mesh/`.
- Added `src/lib.rs` so the required public `workbench_mesh::protocol` interface exists for consumers and tests.

Tests run, exact commands and pass/fail results
- `bash test/mesh-protocol.test.sh` — FAIL (expected red phase before binary existed: `target/debug/workbench-mesh: No such file or directory`)
- `cargo test -p workbench-mesh` — PASS
- `cargo build -p workbench-mesh` — PASS
- `bash test/mesh-protocol.test.sh` — PASS
- `cargo test -p workbench-mesh` — PASS
- `cargo build -p workbench-mesh` — PASS
- `bash test/mesh-protocol.test.sh` — PASS

Commit hash(es)
- `f535ac3`

Self-review notes and any concerns
- Added `src/lib.rs` beyond the brief's file list because the required `workbench_mesh::protocol::{...}` public interface is not possible from a binary-only crate.
- Added `Cargo.lock` as part of introducing a Rust workspace and binary crate.

Fix section: review finding on atomic sequence allocation
- Finding addressed: `crates/workbench-mesh/src/store.rs` now takes an exclusive per-log file lock before scanning for the max `seq`, building the `EventEnvelope`, and appending the JSONL line. The same locked append path is used for both `events.jsonl` and `audit.jsonl`.
- Dependency update: added `fs2 = "0.4"` to `crates/workbench-mesh/Cargo.toml` and refreshed `Cargo.lock`.

Exact commands and results
- `cargo test -p workbench-mesh store::tests::concurrent_appenders_allocate_unique_contiguous_sequences -- --exact` — FAIL before the fix (`parse .../.workbench/mesh/events.jsonl`, showing concurrent writers could corrupt the log without locking)
- `cargo test -p workbench-mesh store::tests::concurrent_appenders_allocate_unique_contiguous_sequences -- --exact` — PASS after the fix
- `cargo test -p workbench-mesh` — PASS
- `cargo build -p workbench-mesh` — PASS
- `bash test/mesh-protocol.test.sh` — PASS

Fix section: review finding on reader shared locking for event listing
- Finding addressed: `crates/workbench-mesh/src/store.rs` now takes an `fs2::FileExt` shared lock on `events.jsonl` in `list_events_since` and holds it for the full read/parse pass, making readers mutually exclusive with the existing writer exclusive lock on the same file.
- Regression coverage: added `store::tests::list_events_since_waits_for_writer_lock_before_parsing`, a deterministic thread-based unit test that holds the writer lock across a partial trailing JSON line and verifies the reader blocks until the line is completed and the lock is released.
- Clarification: `store::tests::concurrent_appenders_allocate_unique_contiguous_sequences` is a thread-based regression covering concurrent code paths through the file-locking implementation. It is not an inter-process test.

Exact commands and results
- `cargo test -p workbench-mesh store::tests::list_events_since_waits_for_writer_lock_before_parsing -- --exact` — FAIL before the fix (`reader returned before writer released its lock`)
- `cargo test -p workbench-mesh store::tests::list_events_since_waits_for_writer_lock_before_parsing -- --exact` — PASS after the fix
- `cargo test -p workbench-mesh store::tests::concurrent_appenders_allocate_unique_contiguous_sequences -- --exact` — PASS
- `cargo test -p workbench-mesh` — PASS
- `cargo build -p workbench-mesh` — PASS
- `bash test/mesh-protocol.test.sh` — PASS
