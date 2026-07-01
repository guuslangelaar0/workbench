## What you implemented

- Added `test/mesh-plugin-outcome.test.sh`, an offline outcome test that exercises the plugin mesh wrapper surface through `scripts/mesh.sh`.
- The offline test starts mesh in the background, waits for `.workbench/mesh/server.json` and the pid file, opens the command center URL through the wrapper, runs availability/room/message/ask/handoff/invite/who flows, writes the statusline snapshot with the existing Rust CLI, and verifies the cache-only statusline hook output.
- Added the mesh suites to `test/all.sh` after `park` in dependency order: `mesh-protocol mesh-auth mesh-service mesh-ops mesh-packaging mesh-command-center mesh-hooks mesh-plugin-outcome`.
- Extended `test/e2e/run.sh` with live plugin mesh scenarios for local command center open, worker invite creation, and natural collaboration intent.
- Updated the live mesh start/invite scenarios to start the long-running mesh wrapper in the background, wait for server metadata, then exercise `/workbench:mesh open` and `/workbench:mesh invite` without hanging.

## What you tested and test results

- `bash -n test/mesh-plugin-outcome.test.sh test/all.sh test/e2e/run.sh` - pass.
- `bash test/mesh-plugin-outcome.test.sh` - pass.
- Focused mesh suites: `mesh-protocol`, `mesh-auth`, `mesh-service`, `mesh-ops`, `mesh-packaging`, `mesh-command-center`, `mesh-hooks` - pass.
- `WB_E2E=1 bash test/e2e/run.sh` - pass, `E2E PASS (17 checks)`.
- `bash test/all.sh` - pass, `ALL TESTS PASS`.

## Files changed

- `test/mesh-plugin-outcome.test.sh`
- `test/all.sh`
- `test/e2e/run.sh`
- `.superpowers/sdd/task-8-report.md`

## Self-review findings

- The offline outcome test keeps `mesh.sh start` in the background and cleans up the server from the pid file.
- The statusline hook remains cache-only; the test populates the snapshot via `bin/workbench-mesh snapshot statusline`.
- The live E2E prompts no longer ask Claude to run the long-running start command in the foreground.
- No production feature code was changed.

## Any issues or concerns

- No remaining concerns.

## Review remediation

- Updated `test/e2e/run.sh` scenario 11 so the live prompt drives `/workbench:mesh start --local --port 0 --pid-file mesh.pid` through the plugin slash-command surface in the background, waits for server metadata, and then drives `/workbench:mesh open`. The prompt no longer instructs Claude to invoke `scripts/mesh.sh` directly.
- Strengthened scenario 11 assertions to require concrete command-center evidence: `Command center` text, a `http://127.0.0.1:<port>` URL in model output, and persisted local server metadata in `.workbench/mesh/server.json`.
- Strengthened scenario 12 assertions to require a real worker invite token, worker role, expiry, local command-center URL, persisted local server metadata, and `invite.created` audit evidence.
- Strengthened scenario 13 assertions to require persisted `room.created` and `message.sent` events for `lead:checkout` and `what are you touching?`, plus concrete `who` output evidence.

## Review remediation test results

- `bash -n test/e2e/run.sh test/mesh-plugin-outcome.test.sh test/all.sh` - pass.
- `bash test/mesh-plugin-outcome.test.sh` - pass, `PASS: mesh-plugin-outcome`.
- Focused live prompt checks for the updated invite and natural collaboration prompts - pass.
- `WB_E2E=1 bash test/e2e/run.sh` - pass, `E2E PASS (17 checks)`.

## Re-review remediation

- Updated scenario 13 so the live prompt no longer spells out the exact room/message/who slash-command sequence for the collaboration work. It now gives Claude a natural team request, while keeping only the local daemon startup constrained/backgrounded through the Workbench mesh plugin surface.
- Kept the scenario 13 assertions concrete: the JSONL event log must contain `room.created` evidence for `lead:checkout` and `message.sent` evidence for `what are you touching?`.
- Tightened `mesh_event_contains` to parse JSONL with Python and require the requested event type plus regex evidence on the same event line. No `jq` dependency was added.

## Re-review test results

- `bash -n test/e2e/run.sh` - pass.
- Tiny local JSONL helper sanity check - pass; it only succeeded when the requested type and evidence appeared on the same event line.
- `WB_E2E=1 bash test/e2e/run.sh` - diagnostic run failed at scenario 13 with the first natural wording because Claude created `checkout-lead` instead of `lead:checkout`; the prompt was tightened to name the desired room identifier without spelling out the slash-command sequence.
- Focused live scenario 13 check with the final prompt - pass.
