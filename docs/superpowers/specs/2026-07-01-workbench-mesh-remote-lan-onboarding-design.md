# Workbench Mesh Remote LAN Onboarding Design

## Intent

Workbench v0.6.0 should make the natural user request work end to end:

```text
Can you talk to my other Claude session on my MacBook?
```

Claude should map that to safe local/LAN mesh operations without asking the user to know about bridges, sockets, daemon APIs, or credential files. The first machine starts or reuses the mesh, exposes it on the trusted LAN only when explicitly asked, creates a short-lived invite, prints copyable connection commands with hostname, mDNS, raw IP, and port, and the second machine can join with `/workbench:mesh connect http://HOST:PORT TOKEN [DEVICE]`.

This release does not introduce public internet exposure, NAT traversal, WebRTC, gRPC, protobuf, MCP bridges, or federation. Those remain later extensions of the same mesh control plane.

## Current State

v0.5.1 already has the right foundation:

- `workbench-mesh serve` starts a Rust HTTP/WebSocket daemon.
- `scripts/mesh.sh start --local|--lan` prints command-center connection details.
- Same-user local auth is bootstrapped under `$WORKBENCH_HOME/mesh/`.
- Local invites can be created and accepted with `invite create` and `invite accept`.
- The command center can create and revoke invite tokens.
- The wrapper intentionally rejects URL connect because remote invite acceptance is not implemented.

The missing slice is remote acceptance. Today `connect TOKEN [DEVICE]` assumes the invite store and credential store are both local to the same machine. That cannot onboard a second laptop because the daemon must validate a token minted for another device, while the durable cleartext credential must be stored on the joining device, not on the daemon host.

## Approaches Considered

### Recommended: HTTP JSON Remote Accept

Keep the existing HTTP/WebSocket JSON control plane and add a token-gated `POST /api/invites/accept` endpoint. The remote daemon redeems the invite, stores only a hash/registry record for the issued device credential, returns the clear credential once, and the joining machine writes it to its own `$WORKBENCH_HOME/mesh/projects/<device>.cred`.

This matches the shipped architecture, is easy to test with local loopback, and keeps Claude-readable JSON as the protocol for open-source contributors.

### Deferred: WebRTC DataChannels

WebRTC is useful later for peer-to-peer low-latency links and NAT traversal, but it requires signaling, more complicated identity, and browser/runtime concerns. It does not solve the immediate onboarding credential gap.

### Deferred: gRPC/Protobuf

gRPC/protobuf can help once Workbench has stable SDK clients and binary contracts. For v0.6.0 it would add generated-code and tooling overhead while the product behavior is still being proven.

## Product Behavior

### Host Machine

When the user asks to connect another machine, Claude should:

1. Run `/workbench:mesh status` or inspect hook context to see whether mesh is already running.
2. If needed, start it with `/workbench:mesh start --lan`.
3. Create a scoped invite with `/workbench:mesh invite --role worker --ttl-seconds 900`.
4. Show the user concrete connection commands for the other device.
5. Confirm connection by running `/workbench:mesh devices`, `/workbench:mesh who`, or `/workbench:mesh status`.

LAN startup and invite output must include all useful address forms:

```text
Host: guus-macbook.local:47321
LAN IP: 192.168.1.42:47321
Local: 127.0.0.1:47321

Connect from the other machine:
/workbench:mesh connect http://guus-macbook.local:47321 wb_invite_... macbook

Fallback if mDNS fails:
/workbench:mesh connect http://192.168.1.42:47321 wb_invite_... macbook
```

Tokens are printed as command arguments only. They are not embedded in URLs.

### Joining Machine

The joining machine runs:

```text
/workbench:mesh connect http://HOST:PORT wb_invite_... macbook
```

The wrapper should call the Rust binary with URL support:

```text
workbench-mesh invite accept --target <local-project> --home <local-home> --url http://HOST:PORT --token wb_invite_... --device macbook
```

The Rust client should:

1. POST the invite token and device name to the remote daemon.
2. Receive `{ project, role, token, device }` exactly once.
3. Compare the returned `project` with the local project id derived from the local checkout.
4. Refuse to write a credential if the remote project does not match the local project.
5. Store the cleartext credential in `$WORKBENCH_HOME/mesh/projects/<device>.cred` with user-only permissions.
6. Store the device key in `$WORKBENCH_HOME/mesh/devices/<device>.key`.
7. Print a success message without printing the issued bearer token.

Example success:

```text
device macbook connected
project: workbench
role: worker
url: http://guus-macbook.local:47321
credential: ~/.workbench/mesh/projects/macbook.cred
```

## Security Model

Auth remains mandatory on localhost and LAN. LAN exposure is explicit and public internet remains unavailable.

Invite tokens:

- Start with `wb_invite_`.
- Are short-lived.
- Are role-scoped.
- Have bounded uses.
- Are stored hashed in `.workbench/mesh/invites.json`.
- Are never accepted after expiry, exhaustion, or revocation.

Remote device credentials:

- The joining device stores the clear bearer token under `$WORKBENCH_HOME/mesh/projects/` with mode `0600` on Unix.
- The daemon host stores only a credential hash, device name, role, project id, timestamps, and revocation state in ignored runtime state under `.workbench/mesh/`.
- The daemon validates remote bearer tokens by hash against the project device registry, not by reading the joining machine's home directory.
- Revoking a device marks the daemon-side registry record revoked so existing remote bearer tokens stop working immediately.

Sensitive audit and event records:

- `invite.created`
- `invite.accepted`
- `invite.revoked`
- `device.connected`
- `device.revoked`
- `device.auth_rejected` for revoked device credentials; unknown bearer tokens can be rejected without audit to avoid noisy credential probing logs

Audit/event payloads must include token hashes or short token hints only, never raw bearer tokens.

## Runtime Architecture

Add a daemon-side device credential registry:

```text
.workbench/mesh/devices.json
```

Each record contains non-secret validation and inventory data:

```json
{
  "device": "macbook",
  "project": "workbench",
  "role": "worker",
  "credential_hash": "sha256...",
  "accepted_at": "2026-07-01T13:00:00Z",
  "last_seen_at": null,
  "revoked_at": null
}
```

The registry is ignored runtime state, not a user-editable config file. It is safe to keep in the project runtime directory because it contains only credential hashes and inventory metadata.

Refactor auth into two internal operations:

1. Redeem invite in the project runtime store and mint a project credential.
2. Persist the clear credential to the current machine's `$WORKBENCH_HOME`.

Local accept can perform both operations in one process. Remote accept performs redeem on the daemon host and credential persistence on the joining host.

The server token check becomes:

1. Accept the current daemon token.
2. Accept durable same-user local project credentials from the daemon host.
3. Accept non-revoked remote device credential hashes from `.workbench/mesh/devices.json`.

## Command And API Surface

Slash command wrapper:

```text
/workbench:mesh connect TOKEN [DEVICE]
/workbench:mesh connect URL TOKEN [DEVICE]
/workbench:mesh devices
/workbench:mesh revoke-device DEVICE
```

Rust CLI:

```text
workbench-mesh invite accept --target PATH --home PATH --token TOKEN --device DEVICE
workbench-mesh invite accept --target PATH --home PATH --url URL --token TOKEN --device DEVICE
workbench-mesh device list --target PATH --home PATH
workbench-mesh device revoke --target PATH --home PATH --device DEVICE
```

Daemon API:

```text
POST /api/invites/accept
GET  /api/devices
POST /api/devices/revoke
```

`POST /api/invites/accept` is invite-token gated, not bearer-token gated, because a joining device does not have a bearer token yet. Device list and revoke require owner/operator bearer auth.

## Command Center

The command center should gain a compact Devices view or Devices section under Invites:

- Device name.
- Role.
- Accepted timestamp.
- Last seen timestamp when available.
- Revoked state.
- Revoke action for owner/operator tokens.
- No raw bearer token display.

The existing invite role selector must use `observer`, not `viewer`, because `observer` is the actual backend role.

Invite creation output must show copyable connect commands for hostname/mDNS and raw IP when metadata is available. The command center shows the raw invite token only in the immediate create result as the operator's one-time copy surface. It must not persist the raw token into event history, device inventory, URLs, or audit payloads.

## Statusline And Presence

Remote onboarding must be visible without network calls from the Claude terminal statusline:

- Remote accept appends a `device.connected` event.
- Device revoke appends a `device.revoked` event.
- Statusline snapshot generation reads mesh events and includes remote devices in the team pulse.
- The statusline hook continues to read only `$WORKBENCH_HOME/mesh/statusline/<project>.json`; it does not call the daemon.

The compact string must include remote device presence when at least one device is connected, for example:

```text
workbench | session:lead | available | team 2 active, 0 stale | devices macbook
```

## Testing Requirements

Unit and Rust integration tests:

- Remote invite accept returns a credential once and stores only a hash in the daemon-side registry.
- A returned remote credential authenticates `GET /api/state` and WebSocket connections.
- Revoking the device prevents future API/WebSocket use with that credential.
- Expired, exhausted, revoked, unknown, and project-mismatched invites fail without writing a local credential.
- Device names are sanitized consistently for files and registry records.
- Observer devices can read but cannot mutate events or create invites.

Shell tests:

- `scripts/mesh.sh connect http://127.0.0.1:PORT TOKEN laptop` delegates to Rust remote accept instead of failing.
- Wrapper help advertises URL connect syntax only once remote accept exists.
- Invite output prints hostname/mDNS/raw IP connect commands and never embeds tokens in URLs.
- No secret credential files appear under project `.workbench/`.
- Local-only startup still avoids LAN exposure unless the user asked for another machine.

Command center tests:

- Devices section renders.
- Create invite uses backend role `observer`, not `viewer`.
- Revoke device calls `/api/devices/revoke`.
- Unauthorized requests cannot list or revoke devices.

Outcome tests:

- A gated live plugin scenario should ask: "Can you talk to my other Claude session on my MacBook?" and verify that Claude starts LAN mesh only because the request named another machine, creates an invite, prints host/IP/port, prints a URL connect command, and keeps public internet unavailable.
- A local simulated two-device test should run two `$WORKBENCH_HOME` directories against one daemon on `127.0.0.1`, connect the second device through the URL flow, and verify the second credential can read state and post a worker message.

Benchmarks:

- Keep the existing mesh bench as a release gate.
- Add a lightweight remote-auth path check that connects a remote credential and posts at least one message.
- Do not claim gaming-style latency numbers unless a measured benchmark prints them.

## Release Scope

v0.6.0 includes:

- Remote URL invite acceptance.
- Device credential registry with hashed daemon-side validation.
- Device list and revoke commands.
- Command center device inventory and revoke action.
- Updated natural-intent routing for "talk to my other Claude session".
- Docs and README updates for LAN onboarding.
- Changelog `[Unreleased]` entry until release preparation.

v0.6.0 excludes:

- Public internet exposure.
- Hosted relay service.
- NAT traversal.
- WebRTC DataChannels.
- gRPC/protobuf.
- MCP/channel bridge.
- Cross-repo/federated mesh.

## Acceptance Criteria

The feature is done when a fresh user can install Workbench, run a normal natural-language request to connect another LAN device, receive copyable commands, run the connect command on the second device, and see that device in mesh state and the command center. Tests must prove that the accepted remote credential works, revoked credentials stop working, tokens are not leaked in URLs or project files, and local-only operation remains the default.
