use std::env;
use std::fs::{self, OpenOptions};
use std::io::{Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};

use anyhow::{bail, Context, Result};
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use base64::Engine;
use fs2::FileExt;
use rand::RngCore;
use serde::{Deserialize, Serialize};
use serde_json::json;
use sha2::{Digest, Sha256};
use std::time::Duration;
use time::format_description::well_known::Rfc3339;
use time::OffsetDateTime;

use crate::store::MeshStore;

pub struct AuthPaths {
    pub home: PathBuf,
    pub device_dir: PathBuf,
    pub project_dir: PathBuf,
}

pub struct Invite {
    pub token: String,
    pub role: String,
    pub expires_at: String,
    pub max_uses: u32,
    #[allow(dead_code)]
    pub uses: u32,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct StoredInvite {
    token_hash: String,
    role: String,
    expires_at: String,
    max_uses: u32,
    uses: u32,
    revoked_at: Option<String>,
}

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

pub fn paths(home: Option<PathBuf>) -> Result<AuthPaths> {
    let home = resolve_home(home)?;
    let mesh_home = home.join("mesh");
    let device_dir = mesh_home.join("devices");
    let project_dir = mesh_home.join("projects");
    fs::create_dir_all(&device_dir)
        .with_context(|| format!("create device dir {}", device_dir.display()))?;
    fs::create_dir_all(&project_dir)
        .with_context(|| format!("create project dir {}", project_dir.display()))?;
    Ok(AuthPaths {
        home,
        device_dir,
        project_dir,
    })
}

pub fn project_id_for(project_root: &Path) -> Result<String> {
    project_id(project_root)
}

pub fn sanitize_device_name(value: &str) -> String {
    sanitize_name(value)
}

pub fn bootstrap(project_root: &Path, home: Option<PathBuf>) -> Result<String> {
    let auth_paths = paths(home)?;
    let project_id = project_id(project_root)?;
    let device_key = random_secret();
    let project_token = random_secret();

    write_secret_file(
        &auth_paths.device_dir.join(format!("{project_id}.key")),
        &device_key,
    )?;

    let project_cred = ProjectCredential {
        project: project_id.clone(),
        role: "owner".to_string(),
        token: project_token,
    };
    write_secret_file(
        &auth_paths.project_dir.join(format!("{project_id}.cred")),
        &serde_json::to_string_pretty(&project_cred)?,
    )?;

    Ok(format!(
        "local credential ready\nhome: {}\nproject: {}",
        auth_paths.home.display(),
        project_id
    ))
}

pub fn create_invite(
    project_root: &Path,
    home: Option<PathBuf>,
    role: &str,
    ttl_seconds: u64,
    max_uses: u32,
) -> Result<Invite> {
    validate_role(role)?;
    if ttl_seconds == 0 {
        bail!("ttl_seconds must be positive");
    }
    if max_uses == 0 {
        bail!("max_uses must be positive");
    }

    let auth_paths = paths(home)?;
    require_local_invite_authority(project_root, &auth_paths)?;
    let token = format!("wb_invite_{}", random_secret());
    let expires_at = (OffsetDateTime::now_utc() + duration_from_secs(ttl_seconds)?)
        .format(&Rfc3339)
        .context("format invite expiry")?;
    let stored = StoredInvite {
        token_hash: hash_token(&token),
        role: role.to_string(),
        expires_at: expires_at.clone(),
        max_uses,
        uses: 0,
        revoked_at: None,
    };

    let store = MeshStore::open(project_root)?;
    let invite_path = store.root().join("invites.json");
    mutate_invites(&invite_path, |invites| {
        invites.push(stored.clone());
        Ok(())
    })?;
    store.append_audit(
        "invite.created",
        "auth:local",
        json!({
            "role": role,
            "expires_at": expires_at,
            "max_uses": max_uses,
            "token_hash": stored.token_hash,
        }),
    )?;

    Ok(Invite {
        token,
        role: role.to_string(),
        expires_at,
        max_uses,
        uses: 0,
    })
}

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
    let accepted_at = now
        .format(&Rfc3339)
        .context("format device accepted timestamp")?;
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
        &auth_paths
            .device_dir
            .join(format!("{sanitized_device}.key")),
        &random_secret(),
    )?;
    let path = auth_paths
        .project_dir
        .join(format!("{sanitized_device}.cred"));
    write_secret_file(&path, &serde_json::to_string_pretty(credential)?)?;
    Ok(path)
}

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

pub fn revoke_invite(
    project_root: &Path,
    home: Option<PathBuf>,
    token: &str,
    actor: &str,
) -> Result<String> {
    let auth_paths = paths(home)?;
    require_local_invite_authority(project_root, &auth_paths)?;
    let store = MeshStore::open(project_root)?;
    let invite_path = store.root().join("invites.json");
    let token_hash = hash_token(token);
    let revoked_at = OffsetDateTime::now_utc()
        .format(&Rfc3339)
        .context("format revoke timestamp")?;

    mutate_invites(&invite_path, |invites| {
        let invite = invites
            .iter_mut()
            .find(|invite| invite.token_hash == token_hash)
            .ok_or_else(|| anyhow::anyhow!("invite not found"))?;
        if invite.revoked_at.is_none() {
            invite.revoked_at = Some(revoked_at.clone());
        }
        Ok(())
    })?;

    store.append_audit(
        "invite.revoked",
        actor,
        json!({
            "reason": "manual",
            "revoked_at": revoked_at,
            "token_hash": token_hash,
        }),
    )?;

    Ok(format!("invite revoked\nrevoked_at: {revoked_at}"))
}

pub fn check(project_root: &Path, home: Option<PathBuf>, token: &str) -> Result<String> {
    let project_id = project_id(project_root)?;
    let role = project_token_role(project_root, home, token)?;

    Ok(format!("token valid\nproject: {project_id}\nrole: {role}"))
}

pub fn project_token_role(
    project_root: &Path,
    home: Option<PathBuf>,
    token: &str,
) -> Result<String> {
    let auth_paths = paths(home)?;
    let project_id = project_id(project_root)?;
    let token_hash = hash_token(token);
    let devices = device_records(project_root)?;

    if let Some(role) = device_role_for_token(project_root, &project_id, &token_hash, &devices)? {
        return Ok(role);
    }

    for credential in project_credentials_for(&auth_paths, &project_id)? {
        if credential.project == project_id && credential.token == token {
            if credential_token_revoked(&devices, &project_id, &credential.token) {
                bail!("token rejected");
            }
            validate_role(&credential.role)?;
            return Ok(credential.role);
        }
    }

    bail!("token rejected")
}

pub fn local_project_token(project_root: &Path, home: Option<PathBuf>) -> Result<String> {
    let auth_paths = paths(home)?;
    let project_id = project_id(project_root)?;
    project_credentials_for(&auth_paths, &project_id)?
        .into_iter()
        .find(|credential| credential.project == project_id)
        .map(|credential| credential.token)
        .ok_or_else(|| anyhow::anyhow!("local project credential required"))
}

pub fn require_local_project_credential(project_root: &Path, home: Option<PathBuf>) -> Result<()> {
    let auth_paths = paths(home)?;
    require_project_credential_with_roles(
        project_root,
        &auth_paths,
        &["owner", "operator", "worker", "observer"],
        "local project credential required",
    )
}

pub fn require_local_mutating_project_credential(
    project_root: &Path,
    home: Option<PathBuf>,
) -> Result<()> {
    let auth_paths = paths(home)?;
    require_project_credential_with_roles(
        project_root,
        &auth_paths,
        &["owner", "operator", "worker"],
        "local mutating project credential required",
    )
}

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

pub fn validate_role(role: &str) -> Result<()> {
    match role {
        "owner" | "operator" | "worker" | "observer" => Ok(()),
        _ => bail!("invalid role: {role}"),
    }
}

fn resolve_home(home: Option<PathBuf>) -> Result<PathBuf> {
    if let Some(home) = home {
        return Ok(home);
    }
    if let Some(home) = env::var_os("WORKBENCH_HOME") {
        return Ok(PathBuf::from(home));
    }
    let home = env::var_os("HOME").ok_or_else(|| anyhow::anyhow!("HOME is not set"))?;
    Ok(PathBuf::from(home).join(".workbench"))
}

fn require_local_invite_authority(project_root: &Path, auth_paths: &AuthPaths) -> Result<()> {
    require_project_credential_with_roles(
        project_root,
        auth_paths,
        &["owner", "operator"],
        "local owner/operator credential required",
    )
}

fn require_project_credential_with_roles(
    project_root: &Path,
    auth_paths: &AuthPaths,
    roles: &[&str],
    error_message: &str,
) -> Result<()> {
    let project_id = project_id(project_root)?;
    let devices = device_records(project_root)?;
    for credential in project_credentials_for(auth_paths, &project_id)? {
        if roles.contains(&credential.role.as_str())
            && !credential_token_revoked(&devices, &project_id, &credential.token)
        {
            return Ok(());
        }
    }

    bail!("{error_message}")
}

fn device_role_for_token(
    project_root: &Path,
    project_id: &str,
    token_hash: &str,
    devices: &[DeviceRecord],
) -> Result<Option<String>> {
    for device in devices {
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
            return Ok(Some(device.role.clone()));
        }
    }

    Ok(None)
}

fn credential_token_revoked(devices: &[DeviceRecord], project_id: &str, token: &str) -> bool {
    let token_hash = hash_token(token);
    devices.iter().any(|device| {
        device.project == project_id
            && device.credential_hash == token_hash
            && device.revoked_at.is_some()
    })
}

fn device_records(project_root: &Path) -> Result<Vec<DeviceRecord>> {
    read_devices(&project_root.join(".workbench/mesh/devices.json"))
}

fn project_credentials_for(
    auth_paths: &AuthPaths,
    project_id: &str,
) -> Result<Vec<ProjectCredential>> {
    let mut credentials = Vec::new();
    for entry in fs::read_dir(&auth_paths.project_dir).with_context(|| {
        format!(
            "read project credentials {}",
            auth_paths.project_dir.display()
        )
    })? {
        let entry = entry.with_context(|| {
            format!(
                "read project credential entry from {}",
                auth_paths.project_dir.display()
            )
        })?;
        let path = entry.path();
        if !path.is_file()
            || path.extension().and_then(|extension| extension.to_str()) != Some("cred")
        {
            continue;
        }

        let Ok(content) = fs::read(&path) else {
            continue;
        };
        let Ok(credential) = serde_json::from_slice::<ProjectCredential>(&content) else {
            continue;
        };

        if credential.project == project_id {
            credentials.push(credential);
        }
    }

    Ok(credentials)
}

fn project_id(project_root: &Path) -> Result<String> {
    let config_path = project_root.join(".workbench/config.json");
    if config_path.is_file() {
        let config: serde_json::Value = serde_json::from_slice(
            &fs::read(&config_path).with_context(|| format!("read {}", config_path.display()))?,
        )
        .with_context(|| format!("parse {}", config_path.display()))?;
        if let Some(name) = config
            .get("project")
            .and_then(|project| project.get("name"))
            .and_then(|name| name.as_str())
        {
            return Ok(sanitize_name(name));
        }
    }

    let name = project_root
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("project");
    Ok(sanitize_name(name))
}

fn random_secret() -> String {
    let mut bytes = [0_u8; 32];
    rand::thread_rng().fill_bytes(&mut bytes);
    URL_SAFE_NO_PAD.encode(bytes)
}

fn hash_token(token: &str) -> String {
    let digest = Sha256::digest(token.as_bytes());
    digest.iter().map(|byte| format!("{byte:02x}")).collect()
}

fn duration_from_secs(seconds: u64) -> Result<Duration> {
    Ok(Duration::from_secs(seconds))
}

fn sanitize_name(value: &str) -> String {
    let mut sanitized = String::new();
    for ch in value.chars() {
        if ch.is_ascii_alphanumeric() {
            sanitized.push(ch.to_ascii_lowercase());
        } else if matches!(ch, '-' | '_') {
            sanitized.push(ch);
        } else if !sanitized.ends_with('-') {
            sanitized.push('-');
        }
    }
    let trimmed = sanitized.trim_matches('-');
    if trimmed.is_empty() {
        "project".to_string()
    } else {
        trimmed.to_string()
    }
}

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

fn mutate_invites<T>(
    path: &Path,
    mutate: impl FnOnce(&mut Vec<StoredInvite>) -> Result<T>,
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
        let mut invites = if content.trim().is_empty() {
            Vec::new()
        } else {
            serde_json::from_str(&content).with_context(|| format!("parse {}", path.display()))?
        };
        let output = mutate(&mut invites)?;
        file.seek(SeekFrom::Start(0))
            .with_context(|| format!("rewind {}", path.display()))?;
        file.set_len(0)
            .with_context(|| format!("truncate {}", path.display()))?;
        serde_json::to_writer_pretty(&mut file, &invites).context("serialize invites")?;
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

fn write_secret_file(path: &Path, content: &str) -> Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)
            .with_context(|| format!("create parent dir {}", parent.display()))?;
    }

    #[cfg(unix)]
    let mut file = {
        use std::os::unix::fs::OpenOptionsExt;

        OpenOptions::new()
            .create(true)
            .write(true)
            .truncate(true)
            .mode(0o600)
            .open(path)
            .with_context(|| format!("open {}", path.display()))?
    };

    #[cfg(not(unix))]
    let mut file = OpenOptions::new()
        .create(true)
        .write(true)
        .truncate(true)
        .open(path)
        .with_context(|| format!("open {}", path.display()))?;

    file.write_all(content.as_bytes())
        .with_context(|| format!("write {}", path.display()))?;
    file.flush()
        .with_context(|| format!("flush {}", path.display()))?;

    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;

        file.set_permissions(fs::Permissions::from_mode(0o600))
            .with_context(|| format!("set permissions on {}", path.display()))?;
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::{
        accept_invite, bootstrap, check, create_invite, issue_invite_credential, list_devices,
        persist_project_credential, project_token_role, require_local_mutating_project_credential,
        require_local_project_credential, revoke_device, revoke_invite, sanitize_name,
        validate_role, ProjectCredential,
    };
    use std::fs;
    use std::path::Path;

    #[test]
    fn validates_known_roles() {
        validate_role("owner").unwrap();
        validate_role("operator").unwrap();
        validate_role("worker").unwrap();
        validate_role("observer").unwrap();
    }

    #[test]
    fn rejects_unknown_roles() {
        let err = validate_role("lead").unwrap_err();
        assert_eq!(err.to_string(), "invalid role: lead");

        let err = validate_role("admin").unwrap_err();
        assert_eq!(err.to_string(), "invalid role: admin");
    }

    #[test]
    fn bootstrap_project_credential_uses_owner_role() {
        let project = tempfile::tempdir().unwrap();
        let home = tempfile::tempdir().unwrap();
        write_project_config(project.path(), "Mesh Auth");

        bootstrap(project.path(), Some(home.path().to_path_buf())).unwrap();

        let cred_path = home.path().join("mesh/projects/mesh-auth.cred");
        let credential: ProjectCredential =
            serde_json::from_slice(&fs::read(cred_path).unwrap()).unwrap();
        assert_eq!(credential.role, "owner");
    }

    #[test]
    fn create_invite_requires_local_owner_or_operator_credential() {
        let project = tempfile::tempdir().unwrap();
        let home = tempfile::tempdir().unwrap();
        write_project_config(project.path(), "Mesh Auth");

        let err = create_invite(
            project.path(),
            Some(home.path().to_path_buf()),
            "worker",
            900,
            1,
        )
        .err()
        .unwrap();

        assert_eq!(err.to_string(), "local owner/operator credential required");
    }

    #[test]
    fn create_invite_allows_bootstrap_owner_credential() {
        let project = tempfile::tempdir().unwrap();
        let home = tempfile::tempdir().unwrap();
        write_project_config(project.path(), "Mesh Auth");
        bootstrap(project.path(), Some(home.path().to_path_buf())).unwrap();

        let invite = create_invite(
            project.path(),
            Some(home.path().to_path_buf()),
            "worker",
            900,
            1,
        )
        .unwrap();

        assert_eq!(invite.role, "worker");
        assert!(invite.token.starts_with("wb_invite_"));
    }

    #[test]
    fn create_invite_rejects_worker_and_observer_project_credentials() {
        for role in ["worker", "observer"] {
            let project = tempfile::tempdir().unwrap();
            let home = tempfile::tempdir().unwrap();
            write_project_config(project.path(), "Mesh Auth");
            write_project_credential(home.path(), "device.cred", "mesh-auth", role);

            let err = create_invite(
                project.path(),
                Some(home.path().to_path_buf()),
                "worker",
                900,
                1,
            )
            .err()
            .unwrap();

            assert_eq!(
                err.to_string(),
                "local owner/operator credential required",
                "{role} credential must not create invites"
            );
        }
    }

    #[test]
    fn create_invite_allows_operator_project_credential() {
        let project = tempfile::tempdir().unwrap();
        let home = tempfile::tempdir().unwrap();
        write_project_config(project.path(), "Mesh Auth");
        write_project_credential(home.path(), "operator.cred", "mesh-auth", "operator");

        let invite = create_invite(
            project.path(),
            Some(home.path().to_path_buf()),
            "observer",
            900,
            1,
        )
        .unwrap();

        assert_eq!(invite.role, "observer");
    }

    #[test]
    fn revoked_invite_cannot_be_accepted() {
        let project = tempfile::tempdir().unwrap();
        let home = tempfile::tempdir().unwrap();
        write_project_config(project.path(), "Mesh Auth");
        bootstrap(project.path(), Some(home.path().to_path_buf())).unwrap();
        let invite = create_invite(
            project.path(),
            Some(home.path().to_path_buf()),
            "worker",
            900,
            2,
        )
        .unwrap();

        revoke_invite(
            project.path(),
            Some(home.path().to_path_buf()),
            &invite.token,
            "auth:test",
        )
        .unwrap();

        let err = accept_invite(
            project.path(),
            Some(home.path().to_path_buf()),
            &invite.token,
            "macbook",
        )
        .err()
        .unwrap();

        assert_eq!(err.to_string(), "invite revoked");
    }

    #[test]
    fn require_local_project_credential_rejects_uncredentialed_home() {
        let project = tempfile::tempdir().unwrap();
        let home = tempfile::tempdir().unwrap();
        write_project_config(project.path(), "Mesh Auth");

        let err = require_local_project_credential(project.path(), Some(home.path().to_path_buf()))
            .err()
            .unwrap();

        assert_eq!(err.to_string(), "local project credential required");
    }

    #[test]
    fn require_local_project_credential_rejects_wrong_project_credential() {
        let project = tempfile::tempdir().unwrap();
        let home = tempfile::tempdir().unwrap();
        write_project_config(project.path(), "Mesh Auth");
        write_project_credential(home.path(), "other.cred", "other-project", "owner");

        let err = require_local_project_credential(project.path(), Some(home.path().to_path_buf()))
            .err()
            .unwrap();

        assert_eq!(err.to_string(), "local project credential required");
    }

    #[test]
    fn require_local_project_credential_allows_any_valid_project_role() {
        for role in ["owner", "operator", "worker", "observer"] {
            let project = tempfile::tempdir().unwrap();
            let home = tempfile::tempdir().unwrap();
            write_project_config(project.path(), "Mesh Auth");
            write_project_credential(home.path(), "device.cred", "mesh-auth", role);

            require_local_project_credential(project.path(), Some(home.path().to_path_buf()))
                .unwrap_or_else(|err| panic!("{role} should be accepted: {err}"));
        }
    }

    #[test]
    fn require_local_mutating_project_credential_rejects_observer_project_credential() {
        let project = tempfile::tempdir().unwrap();
        let home = tempfile::tempdir().unwrap();
        write_project_config(project.path(), "Mesh Auth");
        write_project_credential(home.path(), "observer.cred", "mesh-auth", "observer");

        let err = super::require_local_mutating_project_credential(
            project.path(),
            Some(home.path().to_path_buf()),
        )
        .err()
        .unwrap();

        assert_eq!(
            err.to_string(),
            "local mutating project credential required"
        );
    }

    #[test]
    fn require_local_mutating_project_credential_allows_owner_operator_and_worker() {
        for role in ["owner", "operator", "worker"] {
            let project = tempfile::tempdir().unwrap();
            let home = tempfile::tempdir().unwrap();
            write_project_config(project.path(), "Mesh Auth");
            write_project_credential(home.path(), "device.cred", "mesh-auth", role);

            super::require_local_mutating_project_credential(
                project.path(),
                Some(home.path().to_path_buf()),
            )
            .unwrap_or_else(|err| panic!("{role} should be accepted: {err}"));
        }
    }

    #[test]
    fn check_accepts_accepted_device_project_credential() {
        let project = tempfile::tempdir().unwrap();
        let home = tempfile::tempdir().unwrap();
        write_project_config(project.path(), "Mesh Auth");
        bootstrap(project.path(), Some(home.path().to_path_buf())).unwrap();
        let invite = create_invite(
            project.path(),
            Some(home.path().to_path_buf()),
            "worker",
            900,
            1,
        )
        .unwrap();
        accept_invite(
            project.path(),
            Some(home.path().to_path_buf()),
            &invite.token,
            "macbook",
        )
        .unwrap();

        let accepted_credential = read_project_credential(home.path(), "macbook.cred");
        let output = check(
            project.path(),
            Some(home.path().to_path_buf()),
            &accepted_credential.token,
        )
        .unwrap();

        assert_eq!(output, "token valid\nproject: mesh-auth\nrole: worker");
    }

    #[test]
    fn check_rejects_wrong_token_when_credential_exists() {
        let project = tempfile::tempdir().unwrap();
        let home = tempfile::tempdir().unwrap();
        write_project_config(project.path(), "Mesh Auth");
        write_project_credential(home.path(), "macbook.cred", "mesh-auth", "worker");

        let err = check(
            project.path(),
            Some(home.path().to_path_buf()),
            "wrong-token",
        )
        .err()
        .unwrap();

        assert_eq!(err.to_string(), "token rejected");
    }

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
        assert!(!project
            .path()
            .join(".workbench/mesh/devices/guus-macbook.key")
            .exists());
        assert!(!project
            .path()
            .join(".workbench/mesh/projects/guus-macbook.cred")
            .exists());
        assert!(project_token_role(
            project.path(),
            Some(home.path().to_path_buf()),
            &credential.token
        )
        .is_ok());
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
        assert!(joining_home
            .path()
            .join("mesh/devices/guus-macbook.key")
            .is_file());
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
        let credential = issue_invite_credential(project.path(), &invite.token, "macbook").unwrap();

        let revoke = revoke_device(project.path(), "macbook", "auth:owner").unwrap();

        assert!(revoke.contains("device revoked"));
        assert!(project_token_role(
            project.path(),
            Some(home.path().to_path_buf()),
            &credential.token
        )
        .is_err());
        let devices = list_devices(project.path()).unwrap();
        assert_eq!(devices[0].revoked_at.is_some(), true);
        assert!(
            std::fs::read_to_string(project.path().join(".workbench/mesh/audit.jsonl"))
                .unwrap()
                .contains("device.revoked")
        );
    }

    #[test]
    fn revoke_device_blocks_local_accepted_project_credential() {
        let project = tempfile::tempdir().unwrap();
        let owner_home = tempfile::tempdir().unwrap();
        let joining_home = tempfile::tempdir().unwrap();
        write_project_config(project.path(), "Mesh Remote");
        bootstrap(project.path(), Some(owner_home.path().to_path_buf())).unwrap();
        let invite = create_invite(
            project.path(),
            Some(owner_home.path().to_path_buf()),
            "worker",
            900,
            1,
        )
        .unwrap();
        accept_invite(
            project.path(),
            Some(joining_home.path().to_path_buf()),
            &invite.token,
            "macbook",
        )
        .unwrap();
        let accepted_credential = read_project_credential(joining_home.path(), "macbook.cred");

        revoke_device(project.path(), "macbook", "auth:owner").unwrap();

        let err = project_token_role(
            project.path(),
            Some(joining_home.path().to_path_buf()),
            &accepted_credential.token,
        )
        .err()
        .unwrap();
        assert_eq!(err.to_string(), "token rejected");

        let err = require_local_mutating_project_credential(
            project.path(),
            Some(joining_home.path().to_path_buf()),
        )
        .err()
        .unwrap();
        assert_eq!(
            err.to_string(),
            "local mutating project credential required"
        );
    }

    #[cfg(unix)]
    #[test]
    fn secret_rewrite_narrows_existing_file_permissions_to_600() {
        use super::write_secret_file;
        use std::os::unix::fs::PermissionsExt;

        let home = tempfile::tempdir().unwrap();
        let secret_path = home.path().join("mesh/devices/device.key");
        fs::create_dir_all(secret_path.parent().unwrap()).unwrap();
        fs::write(&secret_path, "old-secret").unwrap();
        fs::set_permissions(&secret_path, fs::Permissions::from_mode(0o644)).unwrap();

        write_secret_file(&secret_path, "new-secret").unwrap();

        let mode = fs::metadata(&secret_path).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600);
    }

    #[test]
    fn sanitizes_project_names() {
        assert_eq!(sanitize_name("Mesh Auth"), "mesh-auth");
        assert_eq!(sanitize_name("###"), "project");
    }

    fn write_project_config(project: &Path, name: &str) {
        fs::create_dir_all(project.join(".workbench")).unwrap();
        fs::write(
            project.join(".workbench/config.json"),
            format!(r#"{{"project":{{"name":"{name}"}}}}"#),
        )
        .unwrap();
    }

    fn write_project_credential(home: &Path, filename: &str, project: &str, role: &str) {
        let project_dir = home.join("mesh/projects");
        fs::create_dir_all(&project_dir).unwrap();
        let credential = ProjectCredential {
            project: project.to_string(),
            role: role.to_string(),
            token: "test-token".to_string(),
        };
        fs::write(
            project_dir.join(filename),
            serde_json::to_string_pretty(&credential).unwrap(),
        )
        .unwrap();
    }

    fn read_project_credential(home: &Path, filename: &str) -> ProjectCredential {
        serde_json::from_slice(&fs::read(home.join("mesh/projects").join(filename)).unwrap())
            .unwrap()
    }
}
