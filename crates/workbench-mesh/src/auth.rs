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

#[derive(Debug, Serialize, Deserialize)]
struct ProjectCredential {
    project: String,
    role: String,
    token: String,
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

pub fn accept_invite(
    project_root: &Path,
    home: Option<PathBuf>,
    token: &str,
    device: &str,
) -> Result<String> {
    if device.trim().is_empty() {
        bail!("device name is required");
    }

    let auth_paths = paths(home)?;
    let store = MeshStore::open(project_root)?;
    let invite_path = store.root().join("invites.json");
    let token_hash = hash_token(token);
    let now = OffsetDateTime::now_utc();
    let project_id = project_id(project_root)?;

    let (role, revoked_at) = match mutate_invites(&invite_path, |invites| {
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
    }) {
        Ok(values) => values,
        Err(err) => {
            let message = err.to_string();
            let event_type = match message.as_str() {
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
            return Err(err);
        }
    };

    write_secret_file(
        &auth_paths
            .device_dir
            .join(format!("{}.key", sanitize_name(device))),
        &random_secret(),
    )?;
    let project_cred = ProjectCredential {
        project: project_id,
        role: role.clone(),
        token: random_secret(),
    };
    write_secret_file(
        &auth_paths
            .project_dir
            .join(format!("{}.cred", sanitize_name(device))),
        &serde_json::to_string_pretty(&project_cred)?,
    )?;
    store.append_audit(
        "invite.accepted",
        "auth:invite",
        json!({ "device": device, "role": role, "token_hash": token_hash }),
    )?;
    if let Some(revoked_at) = revoked_at {
        store.append_audit(
            "invite.revoked",
            "auth:invite",
            json!({
                "device": device,
                "role": role,
                "reason": "max_uses_reached",
                "revoked_at": revoked_at,
                "token_hash": token_hash,
            }),
        )?;
    }

    Ok(format!("device {device} connected\nrole: {role}"))
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

    for credential in project_credentials_for(&auth_paths, &project_id)? {
        if credential.project == project_id && credential.token == token {
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
    for credential in project_credentials_for(auth_paths, &project_id)? {
        if roles.contains(&credential.role.as_str()) {
            return Ok(());
        }
    }

    bail!("{error_message}")
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
        accept_invite, bootstrap, check, create_invite, require_local_project_credential,
        revoke_invite, sanitize_name, validate_role, ProjectCredential,
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
