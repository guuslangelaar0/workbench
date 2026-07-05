# Mesh LAN Transport Security (TLS + Fingerprint Pinning) — Design

## Problem Statement

Today, `--lan` mode serves the mesh protocol (HTTP + WebSocket) and the browser command-center dashboard entirely in plaintext. Confirmed by code audit: `crates/workbench-mesh` has zero TLS or asymmetric-crypto usage anywhere today (only symmetric hashing for tokens — SHA-256 via `sha2`, random secrets via `rand`); `serve()` binds a plain `tokio::net::TcpListener` and calls `axum::serve` directly with no TLS wrapping; `accept_remote_invite()` hard-rejects any URL scheme other than `"http"`. Any device on the same LAN can passively sniff the bearer token and every event/message in transit, and the client performs zero verification of server identity — it blindly trusts whatever process answers at the given host:port.

## Goals

- Close both passive eavesdropping and active MITM on `--lan` mode, for the device-to-device protocol and the browser dashboard.
- Fully offline: no CA, no DNS, no third-party service dependency — must work on an arbitrary home/office LAN with no internet access.
- No new heavyweight dependency beyond the rustls family already present transitively (via `reqwest`'s `rustls-tls` feature).
- Preserve today's operational simplicity: still fundamentally one `mesh invite` / `mesh connect` copy-paste flow.
- `local` (127.0.0.1-only) mode is unaffected — loopback traffic isn't observable by other users/devices on the network, so there's no risk there to justify the added complexity.

## Non-Goals

- Public/internet-facing hosting (out of scope — mesh is a local/LAN tool).
- A local certificate authority or any CA-signed certificate flow (rejected: installing something into the OS-wide trust store per device is a much bigger, more invasive ask than anything else Workbench does today, for a purely cosmetic payoff — see Alternatives Considered).
- Eliminating the one-time browser certificate warning on the dashboard. Structurally impossible without a CA; this is the same limitation LocalSend has, and is accepted rather than solved.
- A PAKE-based ephemeral pairing protocol (rejected: elegant for a single one-shot handshake, but mesh wants one durable server identity joined by many devices over time via repeated invites — that's a cert-identity shape, not a one-shot pairing-code shape).

## Architecture & Trust Model

The mesh gains a per-project **server identity**: a self-signed keypair, generated once and persisted, following the pattern used by Syncthing and LocalSend (the two most comparable real-world tools: local/LAN-first, ad-hoc device pairing, no CA, no DNS).

Two independent security properties compose:
- **TLS + fingerprint pinning authenticates server → client** — the joining device confirms it's really talking to the host that minted this invite, not an impersonator on the LAN.
- **The existing bearer token still authenticates client → server** — unchanged mechanism (single-use invite token → per-device `ProjectCredential`), now transmitted over an encrypted channel instead of plaintext.

The root of trust is the invite itself: the fingerprint travels **inside the same trusted channel as the token** — not as a separate out-of-band step, and not as an interactive SSH-style "do you trust this fingerprint?" prompt gating the cryptographic layer. This is a deliberate, honestly-stated limitation: if the invite text itself is tampered with before it reaches the joining device (e.g. a compromised clipboard or chat relay), the pinned check alone would "succeed" against a substituted server, because the joining device pins to whatever fingerprint the (tampered) invite says. The human matching-code confirmation (below) is the actual mitigation for that specific residual risk, and it is a genuine mitigation: the host's code is computed locally from its own certificate, never transmitted over the invite channel, so a human comparing both codes catches a substitution the crypto pin alone cannot.

## Certificate Lifecycle

- **Generation**: on the first `mesh start --lan` for a project (no `.workbench/mesh/tls/cert.pem` present yet), the server generates a self-signed EC (P-256) certificate via `rcgen`, with the LAN IP(s) already discovered by `detect_lan_ips()` baked in as SANs.
- **Persistence**: `cert.pem` + `key.pem` are written to `.workbench/mesh/tls/`, file mode `0600`, alongside the existing `server.json`/`devices.json` state. The same keypair is reused indefinitely across restarts — **never auto-regenerated**. Regenerating on every start would silently break every previously-pinned client (their pinned fingerprint would stop matching, and they'd have no way to know why).
- **Rotation**: no automatic rotation. A `mesh rotate-identity` subcommand (or documented manual step: delete `tls/`, restart) explicitly regenerates the keypair — a rare, deliberate, operator-initiated action, mirroring the existing `revoke-device` philosophy already used in this codebase. Every previously-enrolled device needs a fresh invite afterward, since their pinned fingerprint is now stale.
- **Scope**: `local` mode never touches `.workbench/mesh/tls/` at all. A project that has never used `--lan` never has this directory.
- **Metadata**: `ServerMetadata` (`server.rs`) gains a `tls_fingerprint: Option<String>` field so `status`/`who`/`mesh open` can display the current fingerprint without recomputing it from the cert file each time.

## Server-Side TLS Serving

`--lan` mode's `serve()` wraps the existing `TcpListener` with a manual `tokio-rustls` `TlsAcceptor` accept loop, rather than adding the `axum-server` companion crate as a dependency (explicit user preference: stay within the rustls family already pulled in transitively via `reqwest`'s `rustls-tls` feature, no additional third-party crypto-adjacent crate). Each accepted `TcpStream` is upgraded via `acceptor.accept(stream)` into a TLS stream, then served through axum's existing `Router`/`hyper` machinery (exact integration shape — a custom `Accept` implementation for `axum::serve`, vs. a manual per-connection `hyper::server::conn` loop — to be finalized during implementation research, since this needs verifying against the exact `axum`/`hyper` versions pinned in this crate).

`local` mode's `serve()` path is completely untouched: still plain `axum::serve` over a plain listener, no TLS involved.

**Crypto provider: `aws-lc-rs`** (explicit user choice), installed once via `rustls::crypto::CryptoProvider::install_default()` at process startup. Every TLS-capable dependency in the crate — `reqwest` (client HTTP half), `tokio-tungstenite` (client WebSocket half) — is configured to select `aws-lc-rs` specifically, never a mix of `ring` and `aws-lc-rs` in the same dependency graph (mixing providers causes a runtime panic at `ClientConfig::builder()`/`ServerConfig::builder()` time due to provider ambiguity).

**Build/CI impact (required, not optional)**: `aws-lc-rs` compiles a C/assembly codebase at build time and needs `cmake` (and in some cross-compilation setups, NASM) available on the build machine. The release workflow's cross-compilation steps — especially the `cross`-based linux-arm64 build — need `cmake` added to their build environment, and a full cross-compiled release build must be verified to actually succeed with `aws-lc-rs` in the dependency tree before this ships in a tagged release. This is a required CI/build-tooling change that must land as part of this feature's implementation plan, not a follow-up nicety.

**TLS version**: restricted to **1.3 only**. Every client in this system is this same codebase (the browser dashboard is the one external client, and all modern browsers support TLS 1.3), so there is no need to support — or correctly implement — the TLS 1.2 half of the custom certificate verifier described below.

`metadata_host()`/`metadata_url()` switch to `https://`/`wss://` for `lan` mode; unchanged (`http://`/`ws://`) for `local` mode.

## Client-Side Pinning

A custom `rustls::client::danger::ServerCertVerifier` implements the pinning logic:

- **`verify_server_cert`**: computes `SHA-256` of the presented end-entity certificate's DER bytes and compares it against the pinned fingerprint from the invite (constant-time comparison). Any mismatch is a hard error — the connection is aborted. There is no fallback path to CA/webpki validation under any circumstance.
- **`verify_tls12_signature` / `verify_tls13_signature`**: **must delegate** to `rustls::crypto::verify_tls12_signature` / `verify_tls13_signature` using the active crypto provider's `signature_verification_algorithms`. Returning "signature valid" unconditionally from these methods — rather than genuinely delegating — is the single most dangerous implementation mistake possible here: it would make the fingerprint pin purely decorative, since an active MITM could replay the real certificate bytes (which would pass the fingerprint check) while forging the handshake signature, and a verifier that skips real signature verification would accept the forged handshake anyway. **A required negative test**: connecting with a deliberately wrong fingerprint must hard-fail the TLS handshake — this is the load-bearing test for this entire feature.
- **`supported_verify_schemes`**: delegates to the active crypto provider's supported schemes.

The same `ClientConfig` (built once from this verifier) is reused for **both** halves of the client: `reqwest::ClientBuilder::use_preconfigured_tls(config)` for HTTP calls, and `tokio_tungstenite`'s `Connector::Rustls(Arc::new(config))` for the WebSocket connection. One verifier implementation is the single source of truth for pinning — never duplicated between the two transports.

`mesh connect` invoked with a host/URL but no `--fingerprint` must fail immediately with a clear, explicit error. It must never silently fall back to unpinned or CA-validated TLS.

## Invite/Connect Ergonomics

- **Shortened credentials**: both the invite token and the fingerprint are shortened from the current 32-byte (256-bit) values to **16 bytes (128-bit)**, base64url-encoded without padding (~22 characters each, down from ~43). This remains an enormous entropy margin for the actual threat model here — a live network attacker rate-limited by real round-trips against a TTL-bound, single-use invite token, not an offline brute-force target. 128 bits is not a meaningfully weaker practical guarantee than 256 for this purpose.
- **Optional scheme and port**: `mesh connect` accepts a bare host with no scheme and no port. Scheme is unambiguous and implied (`--lan` is TLS-only now, so there is exactly one possible scheme). An omitted port defaults to the mesh's existing standard LAN port (matching `scripts/mesh.sh`'s current default, e.g. `47321`), the same default already used when `--lan` starts without an explicit `--port`.
- **Example printed invite**:
  ```
  token: <22-char base64url>
  Fingerprint code: 482-913
  Run on the other device:
    mesh connect 192.168.1.10 <token> <device> --fingerprint sha256:<22-char base64url>
  ```

## Human Matching-Code Confirmation

A short, human-friendly code (6 decimal digits, formatted e.g. `482-913`) is deterministically derived from the fingerprint.

- **Host side**: `mesh invite` and `mesh status`/`mesh who` print this code, computed locally from the server's own persisted certificate — it is never transmitted over the invite channel itself.
- **Client side**: `mesh connect`, after the TLS handshake has already succeeded (i.e., after the automatic cryptographic fingerprint pin has already matched), computes and displays the same code from the certificate it actually received over the network.
- **Default behavior is context-sensitive**, using TTY detection as the switch:
  - **Interactive** (a real terminal — a human running `connect` directly): blocks on `Confirm code matches host: 482-913 [y/N]` before proceeding to send the invite-accept request. This is genuine defense-in-depth against a *tampered invite string*, not merely a redundant re-check of what the crypto pin already verified — see the Architecture & Trust Model section above for why this specifically closes a gap the pin alone cannot.
  - **Non-interactive** (piped stdin, or invoked programmatically — e.g. a Claude session driving `mesh.sh` as part of an automated device-enrollment flow): the prompt is skipped automatically; `connect` proceeds based purely on the already-mandatory cryptographic fingerprint pin. No hang waiting for input that will never arrive, and no flag required to remember for the common automated case.
  - **`-y`/`--yes` flag**: always available, in both interactive and non-interactive contexts, to skip the confirmation outright. This is a first-class, no-friction option — the operator's explicit choice to trust the pinned fingerprint without the additional human cross-check — not something the tool discourages, warns about, or adds friction to.

## Dashboard (Browser)

The command-center dashboard is served over the same certificate/TLS setup as the device protocol for `--lan` mode. Browsers cannot pin certificates the way the CLI client can, so opening the dashboard over LAN in a browser shows a one-time self-signed-certificate warning per browser/device on first visit. This is a structural limitation — the same one LocalSend has for its own browser-facing share links — not a defect, and is explicitly accepted rather than solved by standing up a local CA (see Non-Goals).

## Alternatives Considered

- **Local trusted root CA (mkcert-style)**: generate a project CA once, install it into each device's OS trust store, issue signed leaf certs from it. Rejected — installing something into the OS-wide trust store is a much bigger, more invasive, more per-OS-fragile ask than anything else Workbench does today, for a payoff that is purely cosmetic (removing the browser warning banner).
- **PAKE-based ephemeral pairing (Magic Wormhole-style, SPAKE2)**: skip certificates entirely; a short one-time code bootstraps an encrypted channel directly. Rejected — elegant for a single ephemeral handshake, but mesh wants one durable server identity joined by many devices over time via repeated invites, which is a certificate-identity shape, not a one-shot pairing-code shape. Also far less proven Rust tooling for this specific reuse pattern.
- **Full interactive pairing handshake (Bluetooth-SSP/Signal-style numeric comparison)**: a live two-way key-exchange session where both sides derive and display a matching code from a fresh cryptographic exchange (not a static invite string), with no token minted until the human confirms. Rejected as disproportionate for now — it requires a genuinely new stateful pairing protocol (session state machine, discovery, timeouts, cancellation) to solve a problem that mostly doesn't apply here (one operator typically runs both devices being paired, over a channel — Slack, AirDrop, typed by hand — that's already reasonably trusted). The lighter matching-code-from-a-static-fingerprint design above gets the same practical "did I pair with the right device" confidence without that architectural leap.

## Security Summary

**Closes**:
- Passive eavesdropping on `--lan` traffic (full TLS 1.3 encryption of the mesh protocol and dashboard).
- Active MITM impersonating the host after an honest invite exchange (fingerprint pin hard-fails the TLS handshake on any mismatch).
- Tampered/substituted invite text, specifically for interactive human use (the matching-code confirmation is a genuine out-of-band check independent of whatever channel carried the invite).

**Explicitly does not solve** (stated honestly, consistent with this project's established practice of not overclaiming security properties — see the mesh pre-release audit's own DM-privacy docs-honesty precedent): if the invite channel is compromised **and** the operator/agent skips or is never shown the human confirmation (non-interactive `connect`, or `-y`), trust reduces to "whatever the invite string says" — identical to today's bearer-token-only trust model. This is not a regression introduced by this feature; it is simply not further improved by it in that specific scenario.

## Testing Requirements (high-level; concrete test cases belong in the implementation plan)

- **Positive path**: `--lan` start → invite → connect succeeds end-to-end; dashboard loads over `https://`; chat/messages traverse successfully over `wss://`.
- **Negative path (required, highest priority)**: a wrong/mismatched fingerprint must hard-fail the TLS handshake — proves the verifier is not silently accepting everything, directly guards against the "verifier fails open" pitfall called out above.
- **`local` mode regression**: completely unaffected — still plain HTTP/WS, all existing tests pass unchanged.
- **Cert persistence**: restarting `--lan` mode reuses the same certificate/fingerprint; it is not regenerated.
- **Non-TTY `connect`** does not hang waiting for confirmation input it will never receive.
- **`-y` flag** skips the confirmation in interactive mode too.
- **CI**: a real cross-compiled release build (especially linux-arm64 via `cross`) succeeds with `aws-lc-rs` in the dependency tree, after `cmake` is added to the build environment — verified with an actual build run, not assumed.

## Execution & Delegation Directives

Per explicit user instruction, this governs how the implementation plan (once written) should be dispatched during subagent-driven execution:

- **Default/general implementation tasks** (CLI wiring, scaffolding, non-security-critical plumbing, docs, tests that aren't the pinning-verifier negative test) — delegate to the `codex:codex-rescue` subagent bridge.
- **Security-critical tasks** — specifically the custom `ServerCertVerifier` implementation, the crypto-provider wiring (`aws-lc-rs` installation and provider-selection across `reqwest`/`tokio-tungstenite`), and any other task where a subtle bug would silently defeat the pinning guarantee — implement using the Fable 5 model (Agent tool `model: "fable"`).
- **Final whole-branch review** (after all tasks land) — perform using Claude Sonnet 5 instances (Agent tool `model: "sonnet"`), rather than defaulting to the single most-capable-model heuristic the subagent-driven-development skill would otherwise suggest for a final review. This is an explicit, deliberate override for this specific piece of work.
