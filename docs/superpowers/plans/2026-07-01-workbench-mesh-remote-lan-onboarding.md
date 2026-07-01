# Workbench Mesh Remote LAN Onboarding Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship v0.6.0 remote/LAN Mesh onboarding so a second machine can join with `/workbench:mesh connect http://HOST:PORT TOKEN [DEVICE]`, receive a local credential, authenticate against the host daemon, and be visible/revocable from CLI, command center, and statusline.

**Architecture:** Keep the v0.5.1 Rust HTTP/WebSocket JSON control plane. Split invite redemption from local credential persistence: the daemon redeems invite tokens, stores hashed remote credential records in `.workbench/mesh/devices.json`, returns the clear bearer credential once, and the joining machine stores it under `$WORKBENCH_HOME/mesh/`. Client commands use the local project credential plus cached remote daemon metadata to call the host daemon.

**Tech Stack:** Rust (`workbench-mesh`, Axum, reqwest, serde_json, fs2, sha2), Bash wrapper/tests, static HTML/CSS/JS command center, existing Workbench shell test harness.

## Global Constraints

- Do not bump plugin version during feature implementation; use `CHANGELOG.md` `[Unreleased]` only.
- Public internet exposure remains unavailable and must not be documented as supported.
- Remote connect syntax is `/workbench:mesh connect http://HOST:PORT TOKEN [DEVICE]`; tokens are command arguments, never URL query parameters.
- The daemon host stores only remote credential hashes, device metadata, timestamps, and revocation state under `.workbench/mesh/`.
- The joining device stores the clear bearer token under `$WORKBENCH_HOME/mesh/projects/<device>.cred` with user-only permissions on Unix.
- The command center may show a raw invite token only in the immediate invite-create result; it must not persist raw tokens into events, audit, URLs, or device inventory.
- The statusline hook must not perform network, build, Git, sleep, or blocking daemon calls.
- Keep WebRTC, gRPC/protobuf, MCP/channel bridge, NAT traversal, hosted relay, and public exposure out of v0.6.0.

---

## File Structure

- `crates/workbench-mesh/src/auth.rs`: Own invite redemption, project credential persistence, daemon-side remote device registry, device listing/revocation, and token role validation.
- `crates/workbench-mesh/src/protocol.rs`: Add device event types to the allowed event list.
- `crates/workbench-mesh/src/server.rs`: Add remote invite accept, devices list, devices revoke APIs; include devices in state; route bearer validation through the updated auth layer.
- `crates/workbench-mesh/src/client.rs`: Add remote invite accept client, remote metadata caching, devices list/revoke clients, and helper functions for remote daemon URLs.
- `crates/workbench-mesh/src/main.rs`: Add `--url` to `invite accept`; add `device list` and `device revoke` CLI commands; make invite/device dispatch async where needed.
- `scripts/mesh.sh`: Advertise and route URL connect; add `devices` and `revoke-device`; print copyable connect commands after invite creation.
- `test/mesh-packaging.test.sh`: Update wrapper expectations for URL connect and new commands.
- `test/mesh-remote-lan.test.sh`: New two-home loopback integration test for remote join, remote auth, and revoke.
- `test/mesh-service.test.sh`: Add direct API checks that unauthenticated device list/revoke is rejected and owner list works.
- `test/mesh-command-center.test.sh`: Assert Devices UI/API behavior and `observer` role mapping.
- `test/mesh-command-center-action-harness.js`: Include new UI controls in the DOM/action harness.
- `crates/workbench-mesh/assets/index.html`: Add Devices navigation/section and fix invite role `observer`.
- `crates/workbench-mesh/assets/app.js`: Track `state.devices`, render devices, create copyable connect commands, revoke devices.
- `crates/workbench-mesh/assets/style.css`: Style device inventory using existing table/band patterns.
- `crates/workbench-mesh/src/statusline.rs`: Add devices to snapshots and compact rendering.
- `hooks/bin/mesh-statusline.sh`: Parse `devices` from cached snapshots and print them without live daemon calls.
- `test/mesh-hooks.test.sh`: Assert cached device display and no token leakage.
- `commands/mesh.md`, `skills/mesh/SKILL.md`, `docs/commands.md`, `docs/concepts.md`, `docs/configuration.md`, `README.md`, `CHANGELOG.md`: Update user-facing routing/docs and `[Unreleased]`.

---

### Task 1: Auth Registry And Device Events

**Files:**
- Modify: `crates/workbench-mesh/src/auth.rs`
- Modify: `crates/workbench-mesh/src/protocol.rs`

**Interfaces:**
- Produces: `pub struct ProjectCredential { pub project: String, pub role: String, pub token: String }`
- Produces: `pub struct DeviceRecord { pub device: String, pub project: String, pub role: String, pub credential_hash: String, pub accepted_at: String, pub last_seen_at: Option<String>, pub revoked_at: Option<String> }`
- Produces: `pub fn project_id_for(project_root: &Path) -> Result<String>`
- Produces: `pub fn issue_invite_credential(project_root: &Path, token: &str, device: &str) -> Result<ProjectCredential>`
- Produces: `pub fn persist_project_credential(home: Option<PathBuf>, device: &str, credential: &ProjectCredential) -> Result<PathBuf>`
- Produces: `pub fn list_devices(project_root: &Path) -> Result<Vec<DeviceRecord>>`
- Produces: `pub fn revoke_device(project_root: &Path, device: &str, actor: &str) -> Result<String>`
- Existing consumer updated: `auth::accept_invite()` calls `issue_invite_credential()` then `persist_project_credential()`.
- Existing consumer updated: `auth::project_token_role()` accepts daemon-side non-revoked `devices.json` credential hashes after local credential files.

- [ ] **Step 1: Add failing auth and protocol tests**

Append these tests inside `crates/workbench-mesh/src/auth.rs` `#[cfg(test)] mod tests`:

```rust
    #[test]
    fn issue_invite_credential_registers_hash_without_local_secret_file() {
        let project = tempfile::tempdir().unwrap();
        let home = tempfile::tempdir().unwrap();
        write_project_config(project.path(), "Mesh Remote");
        bootstrap(project.path(), Some(home.path().to_path_buf())).unwrap();
        let invite = create_invite(
            project.path(),
            Some(home.path().to_path_buf()),
            "worker",
            900,
            1,
        )
        .unwrap();

        let credential =
            issue_invite_credential(project.path(), &invite.token, "Guus MacBook").unwrap();

        assert_eq!(credential.project, "mesh-remote");
        assert_eq!(credential.role, "worker");
        assert!(!credential.token.is_empty());
        let devices = list_devices(project.path()).unwrap();
        assert_eq!(devices.len(), 1);
        assert_eq!(devices[0].device, "guus-macbook");
        assert_eq!(devices[0].role, "worker");
        assert_ne!(devices[0].credential_hash, credential.token);
        assert!(!project.path().join(".workbench/mesh/devices/guus-macbook.key").exists());
        assert!(!project.path().join(".workbench/mesh/projects/guus-macbook.cred").exists());
        assert!(project_token_role(project.path(), Some(home.path().to_path_buf()), &credential.token).is_ok());
    }

    #[test]
    fn persist_project_credential_writes_joining_home_secret_files() {
        let joining_home = tempfile::tempdir().unwrap();
        let credential = ProjectCredential {
            project: "mesh-remote".to_string(),
            role: "worker".to_string(),
            token: "secret-remote-token".to_string(),
        };

        let cred_path = persist_project_credential(
            Some(joining_home.path().to_path_buf()),
            "Guus MacBook",
            &credential,
        )
        .unwrap();

        assert_eq!(
            cred_path,
            joining_home.path().join("mesh/projects/guus-macbook.cred")
        );
        let stored = read_project_credential(joining_home.path(), "guus-macbook.cred");
        assert_eq!(stored.project, "mesh-remote");
        assert_eq!(stored.role, "worker");
        assert_eq!(stored.token, "secret-remote-token");
        assert!(joining_home.path().join("mesh/devices/guus-macbook.key").is_file());
    }

    #[test]
    fn revoke_device_blocks_registered_remote_credential() {
        let project = tempfile::tempdir().unwrap();
        let home = tempfile::tempdir().unwrap();
        write_project_config(project.path(), "Mesh Remote");
        bootstrap(project.path(), Some(home.path().to_path_buf())).unwrap();
        let invite = create_invite(
            project.path(),
            Some(home.path().to_path_buf()),
            "worker",
            900,
            1,
        )
        .unwrap();
        let credential =
            issue_invite_credential(project.path(), &invite.token, "macbook").unwrap();

        let revoke = revoke_device(project.path(), "macbook", "auth:owner").unwrap();

        assert!(revoke.contains("device revoked"));
        assert!(project_token_role(project.path(), Some(home.path().to_path_buf()), &credential.token).is_err());
        let devices = list_devices(project.path()).unwrap();
        assert_eq!(devices[0].revoked_at.is_some(), true);
        assert!(std::fs::read_to_string(project.path().join(".workbench/mesh/audit.jsonl"))
            .unwrap()
            .contains("device.revoked"));
    }
```

Update `crates/workbench-mesh/src/protocol.rs` tests by adding the device event strings to `ALLOWED_EVENT_TYPES` expectations through the production array:

```rust
    "device.connected",
    "device.revoked",
    "device.auth_rejected",
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```bash
cargo test -p workbench-mesh auth::tests::issue_invite_credential_registers_hash_without_local_secret_file auth::tests::persist_project_credential_writes_joining_home_secret_files auth::tests::revoke_device_blocks_registered_remote_credential protocol::tests::validates_known_event_types
```

Expected: FAIL with unresolved functions/types such as `issue_invite_credential`, `DeviceRecord`, `persist_project_credential`, and/or `device.connected` rejected by event validation.

- [ ] **Step 3: Implement auth registry**

In `crates/workbench-mesh/src/protocol.rs`, add the new allowed event types immediately after `"device.capabilities"`:

```rust
    "device.connected",
    "device.revoked",
    "device.auth_rejected",
```

In `crates/workbench-mesh/src/auth.rs`, make `ProjectCredential` public and add `DeviceRecord` near the existing invite/credential structs:

```rust
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProjectCredential {
    pub project: String,
    pub role: String,
    pub token: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DeviceRecord {
    pub device: String,
    pub project: String,
    pub role: String,
    pub credential_hash: String,
    pub accepted_at: String,
    pub last_seen_at: Option<String>,
    pub revoked_at: Option<String>,
}
```

Expose the project id helper:

```rust
pub fn project_id_for(project_root: &Path) -> Result<String> {
    project_id(project_root)
}
```

Add invite issuing and persistence functions above `accept_invite`:

```rust
pub fn issue_invite_credential(
    project_root: &Path,
    token: &str,
    device: &str,
) -> Result<ProjectCredential> {
    if device.trim().is_empty() {
        bail!("device name is required");
    }

    let store = MeshStore::open(project_root)?;
    let invite_path = store.root().join("invites.json");
    let token_hash = hash_token(token);
    let now = OffsetDateTime::now_utc();
    let project_id = project_id(project_root)?;
    let sanitized_device = sanitize_name(device);

    let (role, revoked_at) = redeem_invite(&invite_path, &token_hash, now).map_err(|err| {
        let _ = append_invite_rejection_audit(&store, &err, &sanitized_device, &token_hash);
        err
    })?;

    let credential = ProjectCredential {
        project: project_id.clone(),
        role: role.clone(),
        token: random_secret(),
    };
    let accepted_at = now.format(&Rfc3339).context("format device accepted timestamp")?;
    register_device_record(
        store.root(),
        DeviceRecord {
            device: sanitized_device.clone(),
            project: project_id,
            role: role.clone(),
            credential_hash: hash_token(&credential.token),
            accepted_at: accepted_at.clone(),
            last_seen_at: None,
            revoked_at: None,
        },
    )?;
    store.append_audit(
        "invite.accepted",
        "auth:invite",
        json!({ "device": sanitized_device, "role": role, "token_hash": token_hash }),
    )?;
    store.append_event(
        "device.connected",
        "devices",
        "auth:invite",
        Some(&format!("device:{sanitized_device}")),
        json!({ "device": sanitized_device, "role": role, "accepted_at": accepted_at }),
    )?;
    if let Some(revoked_at) = revoked_at {
        store.append_audit(
            "invite.revoked",
            "auth:invite",
            json!({
                "device": sanitized_device,
                "role": role,
                "reason": "max_uses_reached",
                "revoked_at": revoked_at,
                "token_hash": token_hash,
            }),
        )?;
    }

    Ok(credential)
}

pub fn persist_project_credential(
    home: Option<PathBuf>,
    device: &str,
    credential: &ProjectCredential,
) -> Result<PathBuf> {
    validate_role(&credential.role)?;
    let auth_paths = paths(home)?;
    let sanitized_device = sanitize_name(device);
    write_secret_file(
        &auth_paths.device_dir.join(format!("{sanitized_device}.key")),
        &random_secret(),
    )?;
    let path = auth_paths.project_dir.join(format!("{sanitized_device}.cred"));
    write_secret_file(&path, &serde_json::to_string_pretty(credential)?)?;
    Ok(path)
}
```

Extract the invite mutation from the current `accept_invite` into helper functions:

```rust
fn redeem_invite(
    invite_path: &Path,
    token_hash: &str,
    now: OffsetDateTime,
) -> Result<(String, Option<String>)> {
    mutate_invites(invite_path, |invites| {
        let invite = invites
            .iter_mut()
            .find(|invite| invite.token_hash == token_hash)
            .ok_or_else(|| anyhow::anyhow!("invite not found"))?;
        let expires_at = OffsetDateTime::parse(&invite.expires_at, &Rfc3339)
            .context("parse stored invite expiry")?;
        if now >= expires_at {
            bail!("invite expired");
        }
        if invite.uses >= invite.max_uses {
            bail!("invite exhausted");
        }
        if invite.revoked_at.is_some() {
            bail!("invite revoked");
        }
        invite.uses += 1;
        let revoked_at = if invite.uses >= invite.max_uses {
            let revoked_at = now.format(&Rfc3339).context("format revoke timestamp")?;
            invite.revoked_at = Some(revoked_at.clone());
            Some(revoked_at)
        } else {
            invite.revoked_at.clone()
        };
        Ok((invite.role.clone(), revoked_at))
    })
}

fn append_invite_rejection_audit(
    store: &MeshStore,
    err: &anyhow::Error,
    device: &str,
    token_hash: &str,
) -> Result<()> {
    let event_type = match err.to_string().as_str() {
        "invite expired" => Some("invite.expired"),
        "invite exhausted" => Some("invite.exhausted"),
        "invite revoked" => Some("invite.revoked"),
        _ => None,
    };
    if let Some(event_type) = event_type {
        store.append_audit(
            event_type,
            "auth:invite",
            json!({ "device": device, "token_hash": token_hash }),
        )?;
    }
    Ok(())
}
```

Replace the body of `accept_invite` with:

```rust
pub fn accept_invite(
    project_root: &Path,
    home: Option<PathBuf>,
    token: &str,
    device: &str,
) -> Result<String> {
    let credential = issue_invite_credential(project_root, token, device)?;
    let credential_path = persist_project_credential(home, device, &credential)?;
    Ok(format!(
        "device {} connected\nrole: {}\ncredential: {}",
        sanitize_name(device),
        credential.role,
        credential_path.display()
    ))
}
```

Add device registry helpers near `mutate_invites`:

```rust
pub fn list_devices(project_root: &Path) -> Result<Vec<DeviceRecord>> {
    let store = MeshStore::open(project_root)?;
    read_devices(&store.root().join("devices.json"))
}

pub fn revoke_device(project_root: &Path, device: &str, actor: &str) -> Result<String> {
    let store = MeshStore::open(project_root)?;
    let path = store.root().join("devices.json");
    let sanitized_device = sanitize_name(device);
    let revoked_at = OffsetDateTime::now_utc()
        .format(&Rfc3339)
        .context("format device revoke timestamp")?;
    mutate_devices(&path, |devices| {
        let record = devices
            .iter_mut()
            .find(|record| record.device == sanitized_device)
            .ok_or_else(|| anyhow::anyhow!("device not found"))?;
        if record.revoked_at.is_none() {
            record.revoked_at = Some(revoked_at.clone());
        }
        Ok(())
    })?;
    store.append_audit(
        "device.revoked",
        actor,
        json!({ "device": sanitized_device, "revoked_at": revoked_at }),
    )?;
    store.append_event(
        "device.revoked",
        "devices",
        actor,
        Some(&format!("device:{sanitized_device}")),
        json!({ "device": sanitized_device, "revoked_at": revoked_at }),
    )?;
    Ok(format!("device revoked\nrevoked_at: {revoked_at}"))
}

fn register_device_record(root: &Path, record: DeviceRecord) -> Result<()> {
    mutate_devices(&root.join("devices.json"), |devices| {
        devices.retain(|existing| existing.device != record.device);
        devices.push(record);
        Ok(())
    })
}

fn read_devices(path: &Path) -> Result<Vec<DeviceRecord>> {
    if !path.is_file() {
        return Ok(Vec::new());
    }
    let content = fs::read_to_string(path).with_context(|| format!("read {}", path.display()))?;
    if content.trim().is_empty() {
        return Ok(Vec::new());
    }
    serde_json::from_str(&content).with_context(|| format!("parse {}", path.display()))
}

fn mutate_devices<T>(
    path: &Path,
    mutate: impl FnOnce(&mut Vec<DeviceRecord>) -> Result<T>,
) -> Result<T> {
    let mut file = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .open(path)
        .with_context(|| format!("open {}", path.display()))?;
    file.lock_exclusive()
        .with_context(|| format!("lock {}", path.display()))?;
    let result = (|| {
        let mut content = String::new();
        file.read_to_string(&mut content)
            .with_context(|| format!("read {}", path.display()))?;
        let mut devices = if content.trim().is_empty() {
            Vec::new()
        } else {
            serde_json::from_str(&content).with_context(|| format!("parse {}", path.display()))?
        };
        let output = mutate(&mut devices)?;
        file.seek(SeekFrom::Start(0))
            .with_context(|| format!("rewind {}", path.display()))?;
        file.set_len(0)
            .with_context(|| format!("truncate {}", path.display()))?;
        serde_json::to_writer_pretty(&mut file, &devices).context("serialize devices")?;
        file.write_all(b"\n")
            .with_context(|| format!("write newline to {}", path.display()))?;
        file.flush()
            .with_context(|| format!("flush {}", path.display()))?;
        Ok(output)
    })();
    file.unlock()
        .with_context(|| format!("unlock {}", path.display()))?;
    result
}
```

Update `project_token_role` so it checks local credentials first, then device registry hashes:

```rust
pub fn project_token_role(
    project_root: &Path,
    home: Option<PathBuf>,
    token: &str,
) -> Result<String> {
    let auth_paths = paths(home)?;
    let project_id = project_id(project_root)?;

    for credential in project_credentials_for(&auth_paths, &project_id)? {
        if credential.project == project_id && credential.token == token {
            validate_role(&credential.role)?;
            return Ok(credential.role);
        }
    }

    let token_hash = hash_token(token);
    for device in list_devices(project_root)? {
        if device.project == project_id && device.credential_hash == token_hash {
            if device.revoked_at.is_some() {
                let store = MeshStore::open(project_root)?;
                store.append_audit(
                    "device.auth_rejected",
                    "auth:device",
                    json!({ "device": device.device, "reason": "revoked" }),
                )?;
                bail!("token rejected");
            }
            validate_role(&device.role)?;
            touch_device_seen(project_root, &device.device)?;
            return Ok(device.role);
        }
    }

    bail!("token rejected")
}

fn touch_device_seen(project_root: &Path, device: &str) -> Result<()> {
    let store = MeshStore::open(project_root)?;
    let path = store.root().join("devices.json");
    let seen_at = OffsetDateTime::now_utc()
        .format(&Rfc3339)
        .context("format device seen timestamp")?;
    mutate_devices(&path, |devices| {
        if let Some(record) = devices.iter_mut().find(|record| record.device == device) {
            record.last_seen_at = Some(seen_at);
        }
        Ok(())
    })
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run:

```bash
cargo fmt --check
cargo test -p workbench-mesh auth::tests::issue_invite_credential_registers_hash_without_local_secret_file auth::tests::persist_project_credential_writes_joining_home_secret_files auth::tests::revoke_device_blocks_registered_remote_credential protocol::tests::validates_known_event_types
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add crates/workbench-mesh/src/auth.rs crates/workbench-mesh/src/protocol.rs
git commit -m "feat: add mesh device credential registry"
```

---

### Task 2: Remote Accept API And Rust CLI

**Files:**
- Modify: `crates/workbench-mesh/src/server.rs`
- Modify: `crates/workbench-mesh/src/client.rs`
- Modify: `crates/workbench-mesh/src/main.rs`

**Interfaces:**
- Consumes from Task 1: `auth::issue_invite_credential`, `auth::persist_project_credential`, `auth::project_id_for`, `auth::list_devices`, `auth::revoke_device`, `auth::ProjectCredential`.
- Produces API: `POST /api/invites/accept`, `GET /api/devices`, `POST /api/devices/revoke`.
- Produces CLI: `workbench-mesh invite accept --url URL --token TOKEN --device DEVICE`.
- Produces CLI: `workbench-mesh device list --target PATH --home PATH`.
- Produces CLI: `workbench-mesh device revoke --target PATH --home PATH --device DEVICE`.
- Produces client helper: `pub async fn accept_remote_invite(project_root: PathBuf, home: Option<PathBuf>, url: String, token: String, device: String) -> Result<()>`.

- [ ] **Step 1: Add failing Rust tests**

In `crates/workbench-mesh/src/server.rs` tests, add:

```rust
    #[tokio::test]
    async fn remote_invite_accept_returns_credential_and_revoke_blocks_it() {
        let project = TempDir::new().unwrap();
        let home = TempDir::new().unwrap();
        write_project_config(project.path(), "Mesh Remote");
        auth::bootstrap(project.path(), Some(home.path().to_path_buf())).unwrap();
        let owner_token =
            auth::local_project_token(project.path(), Some(home.path().to_path_buf())).unwrap();
        let invite = auth::create_invite(
            project.path(),
            Some(home.path().to_path_buf()),
            "worker",
            900,
            1,
        )
        .unwrap();

        let server = tokio::spawn(serve(ServeOptions {
            project_root: project.path().to_path_buf(),
            home: Some(home.path().to_path_buf()),
            bind: "local".to_string(),
            port: 0,
            pid_file: None,
        }));
        let metadata = wait_for_metadata(project.path()).await;
        let base = format!("http://{}:{}", metadata.host, metadata.port);
        let client = Client::new();

        let accepted: Value = client
            .post(format!("{base}/api/invites/accept"))
            .json(&json!({ "token": invite.token, "device": "macbook" }))
            .send()
            .await
            .unwrap()
            .error_for_status()
            .unwrap()
            .json()
            .await
            .unwrap();
        assert_eq!(accepted["project"], "mesh-remote");
        assert_eq!(accepted["role"], "worker");
        assert_eq!(accepted["device"], "macbook");
        let remote_token = accepted["token"].as_str().unwrap();
        assert!(!remote_token.is_empty());

        let state_response = client
            .get(format!("{base}/api/state"))
            .bearer_auth(remote_token)
            .send()
            .await
            .unwrap();
        assert_eq!(state_response.status(), reqwest::StatusCode::OK);

        let devices: Value = client
            .get(format!("{base}/api/devices"))
            .bearer_auth(&owner_token)
            .send()
            .await
            .unwrap()
            .error_for_status()
            .unwrap()
            .json()
            .await
            .unwrap();
        assert_eq!(devices["devices"][0]["device"], "macbook");
        assert!(devices.to_string().find(remote_token).is_none());

        let revoke = client
            .post(format!("{base}/api/devices/revoke"))
            .bearer_auth(&owner_token)
            .json(&json!({ "device": "macbook" }))
            .send()
            .await
            .unwrap();
        assert_eq!(revoke.status(), reqwest::StatusCode::OK);

        let rejected = client
            .get(format!("{base}/api/state"))
            .bearer_auth(remote_token)
            .send()
            .await
            .unwrap();
        assert_eq!(rejected.status(), reqwest::StatusCode::UNAUTHORIZED);

        server.abort();
    }

    #[tokio::test]
    async fn device_api_requires_owner_or_operator_for_inventory() {
        let project = TempDir::new().unwrap();
        let home = TempDir::new().unwrap();
        write_project_config(project.path(), "Mesh Remote");
        auth::bootstrap(project.path(), Some(home.path().to_path_buf())).unwrap();
        let worker_token = accept_role(project.path(), home.path(), "worker", "worker");

        let server = tokio::spawn(serve(ServeOptions {
            project_root: project.path().to_path_buf(),
            home: Some(home.path().to_path_buf()),
            bind: "local".to_string(),
            port: 0,
            pid_file: None,
        }));
        let metadata = wait_for_metadata(project.path()).await;
        let base = format!("http://{}:{}", metadata.host, metadata.port);

        let unauth = Client::new()
            .get(format!("{base}/api/devices"))
            .send()
            .await
            .unwrap();
        assert_eq!(unauth.status(), reqwest::StatusCode::UNAUTHORIZED);

        let worker = Client::new()
            .get(format!("{base}/api/devices"))
            .bearer_auth(&worker_token)
            .send()
            .await
            .unwrap();
        assert_eq!(worker.status(), reqwest::StatusCode::FORBIDDEN);

        server.abort();
    }
```

In `crates/workbench-mesh/src/client.rs` tests, add:

```rust
    #[test]
    fn remote_metadata_url_rejects_non_http_scheme() {
        let err = super::remote_metadata_from_url("ssh://example.com:47321").unwrap_err();
        assert!(err.to_string().contains("remote mesh URL must use http"));
    }
```

In `crates/workbench-mesh/src/main.rs` tests, add:

```rust
    #[test]
    fn parses_remote_invite_accept_url() {
        let cli = Cli::try_parse_from([
            "workbench-mesh",
            "invite",
            "accept",
            "--target",
            "/tmp/project",
            "--home",
            "/tmp/home",
            "--url",
            "http://127.0.0.1:47321",
            "--token",
            "wb_invite_test",
            "--device",
            "macbook",
        ])
        .unwrap();

        match cli.command {
            Command::Invite(invite) => match invite.command {
                InviteSubcommand::Accept(args) => {
                    assert_eq!(args.url.as_deref(), Some("http://127.0.0.1:47321"));
                    assert_eq!(args.token, "wb_invite_test");
                    assert_eq!(args.device, "macbook");
                }
                other => panic!("expected invite accept, got {other:?}"),
            },
            other => panic!("expected invite command, got {other:?}"),
        }
    }

    #[test]
    fn parses_device_revoke() {
        let cli = Cli::try_parse_from([
            "workbench-mesh",
            "device",
            "revoke",
            "--target",
            "/tmp/project",
            "--home",
            "/tmp/home",
            "--device",
            "macbook",
        ])
        .unwrap();

        match cli.command {
            Command::Device(device) => match device.command {
                DeviceSubcommand::Revoke(args) => assert_eq!(args.device, "macbook"),
                other => panic!("expected device revoke, got {other:?}"),
            },
            other => panic!("expected device command, got {other:?}"),
        }
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```bash
cargo test -p workbench-mesh remote_invite_accept_returns_credential_and_revoke_blocks_it device_api_requires_owner_or_operator_for_inventory remote_metadata_url_rejects_non_http_scheme parses_remote_invite_accept_url parses_device_revoke
```

Expected: FAIL with missing routes, missing CLI fields, missing `Command::Device`, and missing `remote_metadata_from_url`.

- [ ] **Step 3: Implement server API**

In `crates/workbench-mesh/src/server.rs`, add request structs near invite requests:

```rust
#[derive(Debug, Deserialize)]
struct AcceptInviteRequest {
    token: String,
    device: String,
}

#[derive(Debug, Deserialize)]
struct RevokeDeviceRequest {
    device: String,
}
```

Register routes in `serve`:

```rust
        .route("/api/invites/accept", post(post_accept_invite))
        .route("/api/devices", get(api_devices))
        .route("/api/devices/revoke", post(post_revoke_device))
```

Add handlers after `post_revoke_invite`:

```rust
async fn post_accept_invite(
    State(state): State<AppState>,
    Json(request): Json<AcceptInviteRequest>,
) -> Result<Json<Value>, ApiError> {
    let credential =
        auth::issue_invite_credential(&state.project_root, &request.token, &request.device)?;
    Ok(Json(json!({
        "project": credential.project,
        "role": credential.role,
        "token": credential.token,
        "device": auth::sanitize_device_name(&request.device),
    })))
}

async fn api_devices(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<Json<Value>, ApiError> {
    let role = bearer_role(&state, &headers)?;
    if !matches!(role.as_str(), "owner" | "operator") {
        return Err(ApiError::forbidden("owner/operator bearer required"));
    }
    Ok(Json(json!({ "devices": auth::list_devices(&state.project_root)? })))
}

async fn post_revoke_device(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(request): Json<RevokeDeviceRequest>,
) -> Result<Json<Value>, ApiError> {
    let role = bearer_role(&state, &headers)?;
    if !matches!(role.as_str(), "owner" | "operator") {
        return Err(ApiError::forbidden("owner/operator bearer required"));
    }
    let output = auth::revoke_device(
        &state.project_root,
        &request.device,
        &format!("auth:{role}"),
    )?;
    Ok(Json(json!({ "ok": true, "result": output })))
}
```

Update `state_json` to include devices:

```rust
    let devices = auth::list_devices(&state.project_root)?;
    Ok(json!({
        "event_count": events.len(),
        "connected_actor_count": actors.len(),
        "actors": actors.into_iter().collect::<Vec<_>>(),
        "devices": devices,
        "events": events,
        "last_seq": events.last().map(|event| event.seq).unwrap_or(0),
    }))
```

Make `write_server_metadata` public so the remote client can cache remote daemon metadata:

```rust
pub fn write_server_metadata(project_root: &Path, metadata: &ServerMetadata) -> Result<()> {
```

Expose sanitized device names from auth by adding:

```rust
pub fn sanitize_device_name(value: &str) -> String {
    sanitize_name(value)
}
```

- [ ] **Step 4: Implement remote client and CLI**

In `crates/workbench-mesh/src/client.rs`, import metadata writing and URL parsing:

```rust
use reqwest::{Client, Url};

use crate::server::{read_server_metadata, write_server_metadata, ServerMetadata};
```

Add remote invite accept:

```rust
pub async fn accept_remote_invite(
    project_root: PathBuf,
    home: Option<PathBuf>,
    url: String,
    token: String,
    device: String,
) -> Result<()> {
    let metadata = remote_metadata_from_url(&url)?;
    let response = Client::new()
        .post(format!("{}/api/invites/accept", base_url(&metadata)))
        .json(&json!({ "token": token, "device": device }))
        .send()
        .await
        .context("post remote invite accept")?
        .error_for_status()
        .context("remote invite rejected")?;
    let credential: auth::ProjectCredential = response
        .json()
        .await
        .context("parse remote invite credential")?;
    let local_project = auth::project_id_for(&project_root)?;
    if credential.project != local_project {
        anyhow::bail!(
            "remote project mismatch: expected {local_project}, got {}",
            credential.project
        );
    }
    let credential_path =
        auth::persist_project_credential(home, &device, &credential)?;
    write_server_metadata(&project_root, &metadata)?;
    println!("device {} connected", auth::sanitize_device_name(&device));
    println!("project: {}", credential.project);
    println!("role: {}", credential.role);
    println!("url: {}", base_url(&metadata));
    println!("credential: {}", credential_path.display());
    Ok(())
}

pub(crate) fn remote_metadata_from_url(url: &str) -> Result<ServerMetadata> {
    let parsed = Url::parse(url).context("parse remote mesh URL")?;
    if parsed.scheme() != "http" {
        anyhow::bail!("remote mesh URL must use http");
    }
    let host = parsed
        .host_str()
        .ok_or_else(|| anyhow::anyhow!("remote mesh URL requires a host"))?
        .to_string();
    let port = parsed
        .port_or_known_default()
        .ok_or_else(|| anyhow::anyhow!("remote mesh URL requires a port"))?;
    Ok(ServerMetadata {
        mode: "remote".to_string(),
        host: host.clone(),
        port,
        hostname: host.clone(),
        mdns: if host.ends_with(".local") { host.clone() } else { String::new() },
        lan_ips: Vec::new(),
        local_token: String::new(),
    })
}
```

Add devices clients:

```rust
pub async fn list_devices(project_root: PathBuf, home: Option<PathBuf>) -> Result<()> {
    auth::require_local_project_credential(&project_root, home.clone())?;
    let token = auth::local_project_token(&project_root, home)?;
    let metadata = read_server_metadata(&project_root)?;
    let body: Value = Client::new()
        .get(format!("{}/api/devices", base_url(&metadata)))
        .bearer_auth(&token)
        .send()
        .await
        .context("get daemon devices")?
        .error_for_status()
        .context("daemon devices rejected")?
        .json()
        .await
        .context("parse daemon devices")?;
    if let Some(devices) = body.get("devices").and_then(Value::as_array) {
        for device in devices {
            println!(
                "{} role={} revoked={}",
                device.get("device").and_then(Value::as_str).unwrap_or("-"),
                device.get("role").and_then(Value::as_str).unwrap_or("-"),
                device.get("revoked_at").map(|v| !v.is_null()).unwrap_or(false)
            );
        }
    }
    Ok(())
}

pub async fn revoke_device(
    project_root: PathBuf,
    home: Option<PathBuf>,
    device: String,
) -> Result<()> {
    auth::require_local_project_credential(&project_root, home.clone())?;
    let token = auth::local_project_token(&project_root, home)?;
    let metadata = read_server_metadata(&project_root)?;
    Client::new()
        .post(format!("{}/api/devices/revoke", base_url(&metadata)))
        .bearer_auth(&token)
        .json(&json!({ "device": device }))
        .send()
        .await
        .context("post daemon device revoke")?
        .error_for_status()
        .context("daemon device revoke rejected")?;
    println!("device revoked");
    Ok(())
}
```

In `crates/workbench-mesh/src/main.rs`, update `InviteAcceptArgs`:

```rust
#[derive(Debug, Args)]
struct InviteAcceptArgs {
    #[arg(long)]
    target: PathBuf,
    #[arg(long)]
    home: Option<PathBuf>,
    #[arg(long)]
    url: Option<String>,
    #[arg(long)]
    token: String,
    #[arg(long)]
    device: String,
}
```

Add device command types:

```rust
    Device(DeviceCommand),
```

```rust
#[derive(Debug, Args)]
struct DeviceCommand {
    #[command(subcommand)]
    command: DeviceSubcommand,
}

#[derive(Debug, Subcommand)]
enum DeviceSubcommand {
    List(DeviceListArgs),
    Revoke(DeviceRevokeArgs),
}

#[derive(Debug, Args)]
struct DeviceListArgs {
    #[arg(long)]
    target: PathBuf,
    #[arg(long)]
    home: Option<PathBuf>,
}

#[derive(Debug, Args)]
struct DeviceRevokeArgs {
    #[arg(long)]
    target: PathBuf,
    #[arg(long)]
    home: Option<PathBuf>,
    #[arg(long)]
    device: String,
}
```

Change the main match:

```rust
        Command::Invite(invite) => run_invite(invite).await,
        Command::Device(device) => run_device(device).await,
```

Replace `run_invite` and `invite_accept`:

```rust
async fn run_invite(invite_command: InviteCommand) -> Result<()> {
    match invite_command.command {
        InviteSubcommand::Create(args) => invite_create(args),
        InviteSubcommand::Accept(args) => invite_accept(args).await,
    }
}

async fn invite_accept(args: InviteAcceptArgs) -> Result<()> {
    if let Some(url) = args.url {
        client::accept_remote_invite(args.target, args.home, url, args.token, args.device).await
    } else {
        println!(
            "{}",
            auth::accept_invite(&args.target, args.home, &args.token, &args.device)?
        );
        Ok(())
    }
}

async fn run_device(device_command: DeviceCommand) -> Result<()> {
    match device_command.command {
        DeviceSubcommand::List(args) => client::list_devices(args.target, args.home).await,
        DeviceSubcommand::Revoke(args) => {
            client::revoke_device(args.target, args.home, args.device).await
        }
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run:

```bash
cargo fmt --check
cargo test -p workbench-mesh remote_invite_accept_returns_credential_and_revoke_blocks_it device_api_requires_owner_or_operator_for_inventory remote_metadata_url_rejects_non_http_scheme parses_remote_invite_accept_url parses_device_revoke
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add crates/workbench-mesh/src/server.rs crates/workbench-mesh/src/client.rs crates/workbench-mesh/src/main.rs
git commit -m "feat: accept mesh invites over lan"
```

---

### Task 3: Slash Wrapper And Two-Device Shell Test

**Files:**
- Modify: `scripts/mesh.sh`
- Modify: `test/mesh-packaging.test.sh`
- Create: `test/mesh-remote-lan.test.sh`

**Interfaces:**
- Consumes from Task 2: Rust CLI `invite accept --url`, `device list`, `device revoke`.
- Produces wrapper operations: `connect [URL] TOKEN [DEVICE]`, `devices`, `revoke-device DEVICE`.
- Produces integration proof: two `$WORKBENCH_HOME` directories connected through one loopback daemon.

- [ ] **Step 1: Update wrapper tests first**

In `test/mesh-packaging.test.sh`, replace the URL-connect failure block with:

```bash
: > "$LOG"
run_wrapper connect http://192.0.2.10:47321 remote-token tablet > "$WRAP_TMP/connect-url.out" 2>&1
chk "wrapper connect URL accepts remote invite" "contains '$LOG' 'cmd|invite|accept|--target|$PROJECT_DIR|--home|$MESH_HOME|--url|http://192.0.2.10:47321|--token|remote-token|--device|tablet'"
chk "wrapper connect URL no longer fails unsupported" "! contains '$WRAP_TMP/connect-url.out' 'remote URL connect is not supported'"
```

Replace help checks:

```bash
chk "wrapper help advertises URL connect syntax" "contains '$WRAP_TMP/help.out' 'connect [URL] TOKEN [DEVICE]'"
chk "wrapper help documents devices operation" "contains '$WRAP_TMP/help.out' 'devices'"
chk "wrapper help documents revoke-device operation" "contains '$WRAP_TMP/help.out' 'revoke-device DEVICE'"
```

Add device command expectations after the existing `watch` expectations:

```bash
run_wrapper devices > "$WRAP_TMP/devices.out" 2>&1
run_wrapper revoke-device laptop > "$WRAP_TMP/revoke-device.out" 2>&1
chk "wrapper devices delegates to rust device list" "contains '$LOG' 'cmd|device|list|--target|$PROJECT_DIR|--home|$MESH_HOME'"
chk "wrapper revoke-device delegates to rust device revoke" "contains '$LOG' 'cmd|device|revoke|--target|$PROJECT_DIR|--home|$MESH_HOME|--device|laptop'"
```

Create `test/mesh-remote-lan.test.sh`:

```bash
#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
HOST_HOME="$(mktemp -d)"
JOIN_HOME="$(mktemp -d)"
PIDF="$TMP/mesh.pid"
trap 'kill "$(cat "$PIDF" 2>/dev/null)" >/dev/null 2>&1 || true; rm -rf "$TMP" "$HOST_HOME" "$JOIN_HOME"' EXIT
fail=0
chk() { if eval "$2"; then echo "ok: $1"; else echo "FAIL: $1" >&2; fail=1; fi; }

bash "$HERE/scripts/init.sh" --name "MeshRemote" --mission "Test." --target "$TMP" --profile full --level crew >/dev/null 2>&1
cargo build -p workbench-mesh >/dev/null || exit 1
BIN="$HERE/target/debug/workbench-mesh"
"$BIN" auth bootstrap --target "$TMP" --home "$HOST_HOME" >/dev/null
"$BIN" serve --target "$TMP" --home "$HOST_HOME" --bind local --port 0 --pid-file "$PIDF" > "$TMP/mesh.log" 2>&1 &
for _ in $(seq 1 50); do [ -f "$TMP/.workbench/mesh/server.json" ] && break; sleep 0.1; done
PORT="$(sed -n 's/.*"port":\([0-9][0-9]*\).*/\1/p' "$TMP/.workbench/mesh/server.json" | head -1)"
OWNER_TOKEN="$(python3 - "$HOST_HOME" <<'PY'
import glob, json, os, sys
path = glob.glob(os.path.join(sys.argv[1], "mesh/projects/*.cred"))[0]
print(json.load(open(path))["token"])
PY
)"
INVITE="$(CLAUDE_PLUGIN_ROOT="$HERE" CLAUDE_PROJECT_DIR="$TMP" WORKBENCH_HOME="$HOST_HOME" bash "$HERE/scripts/mesh.sh" invite --role worker --ttl-seconds 900 --max-uses 1)"
TOKEN="$(printf '%s\n' "$INVITE" | sed -n 's/^token: //p' | head -1)"
chk "invite prints URL connect command" "printf '%s' \"\$INVITE\" | grep -q '/workbench:mesh connect http://'"
chk "invite does not put token in URL query" "! printf '%s' \"\$INVITE\" | grep -q 'token='"

CONNECT="$(CLAUDE_PLUGIN_ROOT="$HERE" CLAUDE_PROJECT_DIR="$TMP" WORKBENCH_HOME="$JOIN_HOME" bash "$HERE/scripts/mesh.sh" connect "http://127.0.0.1:$PORT" "$TOKEN" laptop)"
chk "remote connect prints connected device" "printf '%s' \"\$CONNECT\" | grep -q 'device laptop connected'"
chk "remote connect writes joining credential outside repo" "[ -f '$JOIN_HOME/mesh/projects/laptop.cred' ]"
chk "remote connect writes joining metadata" "grep -q '127.0.0.1' '$TMP/.workbench/mesh/server.json'"
JOIN_TOKEN="$(python3 - "$JOIN_HOME/mesh/projects/laptop.cred" <<'PY'
import json, sys
print(json.load(open(sys.argv[1]))["token"])
PY
)"
chk "repo contains no clear remote bearer token" "! grep -R \"$JOIN_TOKEN\" '$TMP/.workbench/mesh' >/dev/null 2>&1"
STATE="$(curl -fsS "http://127.0.0.1:$PORT/api/state" -H "Authorization: Bearer $JOIN_TOKEN")"
chk "remote credential reads daemon state" "printf '%s' \"\$STATE\" | grep -q 'devices'"
POST="$(curl -fsS -X POST "http://127.0.0.1:$PORT/api/events" \
  -H "Authorization: Bearer $JOIN_TOKEN" -H 'Content-Type: application/json' \
  -d '{"type":"message.sent","room":"repo:meshremote","from":"session:laptop","payload":{"text":"remote hello"}}')"
chk "remote worker can post message" "printf '%s' \"\$POST\" | grep -q 'remote hello'"

DEVICES="$(CLAUDE_PLUGIN_ROOT="$HERE" CLAUDE_PROJECT_DIR="$TMP" WORKBENCH_HOME="$HOST_HOME" bash "$HERE/scripts/mesh.sh" devices)"
chk "devices lists remote laptop" "printf '%s' \"\$DEVICES\" | grep -q 'laptop role=worker'"
CLAUDE_PLUGIN_ROOT="$HERE" CLAUDE_PROJECT_DIR="$TMP" WORKBENCH_HOME="$HOST_HOME" bash "$HERE/scripts/mesh.sh" revoke-device laptop >/dev/null
REVOKED_RC=0
curl -fsS "http://127.0.0.1:$PORT/api/state" -H "Authorization: Bearer $JOIN_TOKEN" >"$TMP/revoked.out" 2>&1 || REVOKED_RC=$?
chk "revoked remote credential is rejected" "[ '$REVOKED_RC' -ne 0 ]"
chk "audit records device revoked" "grep -q 'device.revoked' '$TMP/.workbench/mesh/audit.jsonl'"
chk "owner token still works after revoke" "curl -fsS 'http://127.0.0.1:$PORT/api/state' -H \"Authorization: Bearer $OWNER_TOKEN\" >/dev/null"

[ "$fail" = 0 ] && echo "PASS: mesh-remote-lan" || { echo "mesh-remote-lan test failed"; exit 1; }
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```bash
bash test/mesh-packaging.test.sh
bash test/mesh-remote-lan.test.sh
```

Expected: FAIL because wrapper still rejects URL connect and has no devices/revoke-device operations.

- [ ] **Step 3: Implement wrapper operations**

In `scripts/mesh.sh`, update usage:

```bash
  connect [URL] TOKEN [DEVICE]
  devices
  revoke-device DEVICE
```

Remove the text that says remote URL connect is unavailable.

Add helper functions after `metadata_url`:

```bash
metadata_field() {
  local key="$1" meta="$TARGET/.workbench/mesh/server.json"
  [ -f "$meta" ] || return 1
  sed -n "s/.*\"$key\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$meta" | head -1
}

metadata_port() {
  local meta="$TARGET/.workbench/mesh/server.json"
  [ -f "$meta" ] || return 1
  sed -n 's/.*"port"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$meta" | head -1
}

metadata_lan_ips() {
  local meta="$TARGET/.workbench/mesh/server.json"
  [ -f "$meta" ] || return 1
  tr ',' '\n' < "$meta" | sed -n 's/.*"\([0-9][0-9.]*\)".*/\1/p'
}

print_connect_commands() {
  local token="$1" port host mdns ip
  port="$(metadata_port || true)"
  [ -n "$port" ] || return 0
  host="$(metadata_field hostname || true)"
  mdns="$(metadata_field mdns || true)"
  [ -n "$mdns" ] && printf 'connect: /workbench:mesh connect http://%s:%s %s <device>\n' "$mdns" "$port" "$token"
  [ -n "$host" ] && [ "$host" != "$mdns" ] && printf 'connect-host: /workbench:mesh connect http://%s:%s %s <device>\n' "$host" "$port" "$token"
  for ip in $(metadata_lan_ips || true); do
    [ -n "$ip" ] && printf 'connect-ip: /workbench:mesh connect http://%s:%s %s <device>\n' "$ip" "$port" "$token"
  done
  if url="$(metadata_url)"; then
    printf 'connect-url: /workbench:mesh connect %s %s <device>\n' "$url" "$token"
  fi
}
```

In `invite)`, capture output and append commands:

```bash
    invite_out="$("$BIN" invite create "${PROJECT_ARGS[@]}" "$@")"
    printf '%s\n' "$invite_out"
    token="$(printf '%s\n' "$invite_out" | sed -n 's/^token: //p' | head -1)"
    if url="$(metadata_url)"; then
      printf 'url: %s\n' "$url"
      [ -n "$token" ] && print_connect_commands "$token"
    else
      echo "url: start mesh first with /workbench:mesh start --lan to invite another machine"
    fi
```

In `connect)`, route URL accepts to Rust:

```bash
    url=""
    if [ "${1:-}" != "" ] && printf '%s' "$1" | grep -Eq '^https?://'; then
      url="$1"
      shift
    fi
    token="${1:-}"
    device="${2:-$(host_name)}"
    require_arg "invite token" "$token"
    if [ -n "$url" ]; then
      exec "$BIN" invite accept "${PROJECT_ARGS[@]}" --url "$url" --token "$token" --device "$device"
    fi
    exec "$BIN" invite accept "${PROJECT_ARGS[@]}" --token "$token" --device "$device"
```

Add operations:

```bash
  devices)
    exec "$BIN" device list "${PROJECT_ARGS[@]}" "$@"
    ;;
  revoke-device)
    require_arg "device" "${1:-}"
    exec "$BIN" device revoke "${PROJECT_ARGS[@]}" --device "$1"
    ;;
```

- [ ] **Step 4: Run tests to verify they pass**

Run:

```bash
bash test/mesh-packaging.test.sh
bash test/mesh-remote-lan.test.sh
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/mesh.sh test/mesh-packaging.test.sh test/mesh-remote-lan.test.sh
git commit -m "feat: route mesh url connect"
```

---

### Task 4: Command Center Device Inventory

**Files:**
- Modify: `crates/workbench-mesh/assets/index.html`
- Modify: `crates/workbench-mesh/assets/app.js`
- Modify: `crates/workbench-mesh/assets/style.css`
- Modify: `test/mesh-command-center.test.sh`
- Modify: `test/mesh-command-center-action-harness.js`

**Interfaces:**
- Consumes from Task 2: `/api/state` includes `devices`; `/api/devices`; `/api/devices/revoke`.
- Produces UI state: `state.devices`.
- Produces UI action: `revoke-device`.

- [ ] **Step 1: Add failing UI tests**

In `test/mesh-command-center-action-harness.js`, add `"revoke-device"` to `expectedActions`. Add these ids to the stub element list:

```js
  "device-input",
  "devices-body",
```

Add this default value:

```js
  "device-input": "macbook",
```

In `test/mesh-command-center.test.sh`, add after the invite/audit HTML checks:

```bash
chk "html includes devices view" "printf '%s' \"\$HTML\" | grep -q 'Devices'"
chk "html uses observer backend role" "printf '%s' \"\$HTML\" | grep -q 'value=\"observer\"' && ! printf '%s' \"\$HTML\" | grep -q 'value=\"viewer\"'"
```

Add after JS checks:

```bash
chk "app lists devices" "printf '%s' \"\$JS\" | grep -q '/api/devices'"
chk "app revokes devices" "printf '%s' \"\$JS\" | grep -q '/api/devices/revoke'"
```

Add after the invite revoke API check:

```bash
REMOTE_INVITE="$(curl -fsS -X POST "http://127.0.0.1:$PORT/api/invites" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"role":"worker","ttl_seconds":900,"max_uses":1}')"
REMOTE_TOKEN="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])' <<<"$REMOTE_INVITE")"
curl -fsS -X POST "http://127.0.0.1:$PORT/api/invites/accept" \
  -H 'Content-Type: application/json' \
  -d "{\"token\":\"$REMOTE_TOKEN\",\"device\":\"ui-laptop\"}" >/dev/null
DEVICES_JSON="$(curl -fsS "http://127.0.0.1:$PORT/api/devices" -H "Authorization: Bearer $TOKEN")"
chk "devices api lists accepted device" "printf '%s' \"\$DEVICES_JSON\" | grep -q 'ui-laptop'"
chk "devices api does not leak bearer token" "! printf '%s' \"\$DEVICES_JSON\" | grep -q '\"token\"'"
DEVICE_REVOKE_JSON="$(curl -fsS -X POST "http://127.0.0.1:$PORT/api/devices/revoke" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"device":"ui-laptop"}')"
chk "revoke device calls real API" "printf '%s' \"\$DEVICE_REVOKE_JSON\" | grep -q '\"ok\":true'"
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```bash
bash test/mesh-command-center.test.sh
```

Expected: FAIL because Devices UI ids/actions and `observer` option are not present.

- [ ] **Step 3: Implement command center UI**

In `crates/workbench-mesh/assets/index.html`, add a nav item after Invites:

```html
      <a href="#devices">Devices</a>
```

Change invite role options:

```html
                <option value="worker">Worker</option>
                <option value="operator">Operator</option>
                <option value="observer">Observer</option>
```

Add a devices section after Invites:

```html
        <section id="devices" class="band">
          <div class="band-head">
            <h2>Devices</h2>
            <div class="toolbar">
              <input id="device-input" aria-label="Device" />
              <button type="button" data-action="revoke-device">Revoke device</button>
            </div>
          </div>
          <div class="table-wrap">
            <table>
              <thead>
                <tr><th>Device</th><th>Role</th><th>Accepted</th><th>Last seen</th><th>State</th></tr>
              </thead>
              <tbody id="devices-body"></tbody>
            </table>
          </div>
        </section>
```

In `crates/workbench-mesh/assets/app.js`, extend state:

```js
    devices: [],
```

Bind elements:

```js
    els.device = document.getElementById("device-input");
    els.devicesBody = document.getElementById("devices-body");
```

Hydrate devices in `loadState`:

```js
        state.devices = Array.isArray(data.devices) ? data.devices : [];
```

In `runAction`, handle device revoke:

```js
    } else if (action === "revoke-device") {
      revokeDevice(els.device.value.trim() || message);
      return;
```

Update `createInvite` output:

```js
        var base = "http://" + window.location.host;
        els.inviteOutput.textContent = [
          "token=" + data.token,
          "role=" + data.role,
          "expires_at=" + data.expires_at,
          "connect=/workbench:mesh connect " + base + " " + data.token + " <device>"
        ].join("\n");
        showToast("Created invite for " + data.role + ".");
```

Add revoke function:

```js
  function revokeDevice(device) {
    if (!state.token) {
      showToast("Set a bearer token first.");
      return;
    }
    if (!device) {
      showToast("Enter a device to revoke.");
      return;
    }
    fetch("/api/devices/revoke", {
      method: "POST",
      headers: headers(true),
      body: JSON.stringify({ device: device })
    })
      .then(requireOk)
      .then(function () {
        showToast("Revoked device.");
        return loadState();
      })
      .catch(function (error) {
        showToast(error.message);
      });
  }
```

Render devices from `render()`:

```js
    renderDevices();
```

Add:

```js
  function renderDevices() {
    var rows = state.devices.map(function (device) {
      var revoked = device.revoked_at ? "revoked" : "active";
      return "<tr><td>" + escapeHtml(device.device || "-") + "</td><td>" + escapeHtml(device.role || "-") + "</td><td>" + escapeHtml(shortTime(device.accepted_at)) + "</td><td>" + escapeHtml(shortTime(device.last_seen_at)) + "</td><td>" + chip(revoked) + "</td></tr>";
    });
    els.devicesBody.innerHTML = rows.length ? rows.join("") : row(5, "No devices connected.");
  }
```

Update `renderAudit` regex:

```js
      return /invite|device|decision|lead|task|job|status/.test(event.type || "");
```

No custom CSS is required if the new section uses existing `band`, `toolbar`, and `table-wrap`. If row spacing looks off in screenshots, add only scoped table styles to `crates/workbench-mesh/assets/style.css`.

- [ ] **Step 4: Run tests to verify they pass**

Run:

```bash
bash test/mesh-command-center.test.sh
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add crates/workbench-mesh/assets/index.html crates/workbench-mesh/assets/app.js crates/workbench-mesh/assets/style.css test/mesh-command-center.test.sh test/mesh-command-center-action-harness.js
git commit -m "feat: show mesh devices in command center"
```

---

### Task 5: Statusline, Docs, And Natural Intent Routing

**Files:**
- Modify: `crates/workbench-mesh/src/statusline.rs`
- Modify: `hooks/bin/mesh-statusline.sh`
- Modify: `test/mesh-hooks.test.sh`
- Modify: `commands/mesh.md`
- Modify: `skills/mesh/SKILL.md`
- Modify: `docs/commands.md`
- Modify: `docs/concepts.md`
- Modify: `docs/configuration.md`
- Modify: `README.md`
- Modify: `CHANGELOG.md`
- Modify if needed: `test/command.test.sh`

**Interfaces:**
- Consumes device events from Task 1: `device.connected`, `device.revoked`.
- Produces statusline snapshot field: `devices: Vec<String>`.
- Produces hook output segment: `devices macbook[, other]`.

- [ ] **Step 1: Add failing statusline and docs tests**

In `crates/workbench-mesh/src/statusline.rs`, add field to `StatuslineSnapshot` test expectations first:

```rust
    pub devices: Vec<String>,
```

Add this unit test:

```rust
    #[test]
    fn device_events_appear_in_snapshot_and_rendering() {
        let events = vec![
            event(
                1,
                "device.connected",
                "auth:invite",
                Some("device:macbook"),
                json!({ "device": "macbook", "role": "worker" }),
            ),
            event(
                2,
                "presence.heartbeat",
                "session:lead",
                None,
                json!({ "availability": "available" }),
            ),
        ];

        let snapshot = project_events_snapshot("meshops", &events);

        assert_eq!(snapshot.devices, vec!["macbook"]);
        assert!(super::render_compact(&snapshot).contains("devices macbook"));
    }
```

In `test/mesh-hooks.test.sh`, update the cached snapshot:

```json
{"project":"MeshHooks","current_actor":"checkout lead","availability":"busy","doing":"retry tests","active_count":3,"stale_count":1,"watched":["macbook testing 0042"],"devices":["macbook"],"unread_mentions":2}
```

Add:

```bash
chk "statusline prints connected devices" "printf '%s' \"\$OUT\" | grep -q 'devices macbook'"
```

In `test/command.test.sh`, add:

```bash
chk "mesh command routes remote natural intent" "grep -q 'talk to my MacBook Claude' '$HERE/commands/mesh.md' && grep -q 'connect URL TOKEN' '$HERE/commands/mesh.md'"
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```bash
cargo test -p workbench-mesh statusline::tests::device_events_appear_in_snapshot_and_rendering
bash test/mesh-hooks.test.sh
bash test/command.test.sh
```

Expected: FAIL because snapshot has no `devices` field and the hook does not parse it.

- [ ] **Step 3: Implement statusline devices**

In `crates/workbench-mesh/src/statusline.rs`, add the field:

```rust
    pub devices: Vec<String>,
```

In `project_events_snapshot`, add:

```rust
    let mut devices = BTreeSet::new();
```

Handle device events:

```rust
            "device.connected" => {
                if let Some(device) = event.payload.get("device").and_then(|value| value.as_str()) {
                    devices.insert(device.to_string());
                } else if let Some(to) = &event.to {
                    devices.insert(to.trim_start_matches("device:").to_string());
                }
            }
            "device.revoked" => {
                if let Some(device) = event.payload.get("device").and_then(|value| value.as_str()) {
                    devices.remove(device);
                }
            }
```

Set the field:

```rust
        devices: devices.into_iter().collect(),
```

Update `render_compact`:

```rust
    let devices = if snapshot.devices.is_empty() {
        String::new()
    } else {
        format!(" | devices {}", snapshot.devices.join(", "))
    };
    format!(
        "workbench | {} | {} | team {} active, {} stale{}",
        snapshot.current_actor, activity, snapshot.active_count, snapshot.stale_count, devices
    )
```

In `hooks/bin/mesh-statusline.sh`, parse and print devices:

```bash
devices="$(json_array_strings "$json" devices)"
```

Append to line:

```bash
[ -n "$devices" ] && line="$line | devices $devices"
```

- [ ] **Step 4: Update docs and changelog**

In `commands/mesh.md`, change the routing bullets to include:

```markdown
- "talk to my MacBook Claude" -> status, start with `start --lan` if no LAN mesh is running, create `invite --role worker --ttl-seconds 900`, then show `/workbench:mesh connect URL TOKEN <device>` using hostname/mDNS and raw IP forms.
```

Update command list text:

```markdown
- "show connected devices" -> `devices`.
- "revoke the MacBook device" -> `revoke-device macbook`.
```

In `skills/mesh/SKILL.md`, update Routing:

```markdown
- Use `/workbench:mesh connect URL TOKEN [DEVICE]` when the user is on the joining machine and has an invite URL/token from another trusted LAN host.
- Use `/workbench:mesh devices` and `/workbench:mesh revoke-device <device>` to inspect and remove LAN device credentials.
```

In `docs/commands.md`, replace the deferred connect section with:

```markdown
### `/workbench:mesh connect [URL] TOKEN [DEVICE]`
Accept an invite token for this device. Without `URL`, the token is redeemed against the local project runtime. With `http://HOST:PORT`, the token is redeemed against a trusted LAN mesh host, and the joining device stores its credential under `$WORKBENCH_HOME/mesh/`. The token is a command argument, not a URL parameter.

### `/workbench:mesh devices` / `/workbench:mesh revoke-device DEVICE`
List connected LAN devices or revoke a device credential. Revocation happens on the daemon-side hashed device registry, so an already-issued remote bearer token stops working immediately.
```

In `README.md`, update Quickstart with:

```text
/workbench:mesh connect http://HOST:PORT TOKEN macbook  # join a trusted LAN mesh
```

Update Workbench Mesh paragraph:

```markdown
Remote/LAN joins use short-lived invite tokens exchanged for device credentials stored outside the repo. The host keeps only hashed device credentials and can list/revoke devices through `/workbench:mesh devices` and `/workbench:mesh revoke-device`.
```

In `docs/concepts.md` and `docs/configuration.md`, replace text saying URL acceptance is deferred with text that says URL acceptance is supported for trusted LAN hosts only, and public internet remains out of scope.

In `CHANGELOG.md`, add under `[Unreleased]`:

```markdown
### Added
- Mesh remote/LAN onboarding: `/workbench:mesh connect http://HOST:PORT TOKEN [DEVICE]` redeems a trusted LAN invite through the host daemon, stores the joining device credential outside the repo, and lets the host list/revoke device credentials.

### Changed
- Mesh invite output now includes copyable connect commands using hostname/mDNS and raw IP forms while keeping tokens out of URLs.
- The command center now includes a Devices inventory and uses the backend `observer` role label.

### Fixed
- Remote invite tokens are no longer treated as unsupported or accidentally local-only; revoked remote device credentials stop authenticating immediately.
```

- [ ] **Step 5: Run tests to verify they pass**

Run:

```bash
cargo fmt --check
cargo test -p workbench-mesh statusline::tests::device_events_appear_in_snapshot_and_rendering
bash test/mesh-hooks.test.sh
bash test/command.test.sh
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add crates/workbench-mesh/src/statusline.rs hooks/bin/mesh-statusline.sh test/mesh-hooks.test.sh test/command.test.sh commands/mesh.md skills/mesh/SKILL.md docs/commands.md docs/concepts.md docs/configuration.md README.md CHANGELOG.md
git commit -m "docs: describe mesh remote lan onboarding"
```

---

### Task 6: Full Verification And Release Readiness Gate

**Files:**
- Modify only if verification exposes a defect in files touched by Tasks 1-5.

**Interfaces:**
- Consumes all previous task commits.
- Produces a verified feature branch ready for v0.6.0 release preparation.

- [ ] **Step 1: Run focused Rust verification**

Run:

```bash
cargo fmt --check
cargo test -p workbench-mesh
```

Expected: PASS.

- [ ] **Step 2: Run focused mesh shell suites**

Run:

```bash
bash test/mesh-auth.test.sh
bash test/mesh-service.test.sh
bash test/mesh-command-center.test.sh
bash test/mesh-hooks.test.sh
bash test/mesh-packaging.test.sh
bash test/mesh-plugin-outcome.test.sh
bash test/mesh-ops.test.sh
bash test/mesh-remote-lan.test.sh
```

Expected: each command prints `PASS: ...`.

- [ ] **Step 3: Run plugin validation and benchmark gate**

Run:

```bash
bash scripts/validate-plugin.sh
bash scripts/bench.sh
git diff --check
```

Expected:

```text
publishable
bench: OK
```

and `git diff --check` exits 0.

- [ ] **Step 4: Run optional live gate only when credentials/tokens are available**

Run only when live Claude Code e2e is configured:

```bash
WB_E2E=1 bash test/e2e/run.sh
```

Expected: existing e2e scenarios pass, and any new remote-LAN natural-intent scenario proves Claude starts LAN only because another machine was requested, prints host/IP/port, prints a URL connect command, and keeps public internet unavailable.

- [ ] **Step 5: Commit verification fixes if any were needed**

If a verification-only fix was made:

```bash
git add <fixed-files>
git commit -m "test: verify mesh remote lan onboarding"
```

If no fixes were needed, do not create an empty commit.

- [ ] **Step 6: Report release readiness**

Collect these facts for the final handoff:

```bash
git log --oneline --decorate -6
git status --short
```

Expected: clean worktree, feature commits present, and no version tag yet. v0.6.0 release preparation is a separate release task with version bump, changelog release section, tag, GitHub release notes in the established style, and assets.

---

## Self-Review

- Spec coverage: Task 1 covers hashed daemon-side device registry, invite redemption split, secret persistence outside the repo, revocation, and device events. Task 2 covers URL remote accept, daemon APIs, device list/revoke, project mismatch protection, and remote metadata caching. Task 3 covers slash-command wrapper behavior, copyable connect commands, and a two-home loopback outcome test. Task 4 covers command-center Devices UI, observer role, and no raw bearer token inventory leak. Task 5 covers statusline visibility, natural intent routing, docs, and changelog. Task 6 covers full verification and release-readiness gates.
- Open-marker scan: no unfinished markers, no unspecified file paths, and no instruction that says to invent tests without concrete content.
- Type consistency: `ProjectCredential`, `DeviceRecord`, `issue_invite_credential`, `persist_project_credential`, `list_devices`, `revoke_device`, `accept_remote_invite`, `remote_metadata_from_url`, and `DeviceSubcommand` names are consistent across tasks.
- Scope check: public internet exposure, WebRTC, gRPC/protobuf, MCP/channel bridge, relay service, NAT traversal, and release tagging remain outside this implementation plan.
