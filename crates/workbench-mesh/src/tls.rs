use std::fs;
use std::io::BufReader;
use std::net::IpAddr;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result};
use rcgen::{CertificateParams, DistinguishedName, DnType, KeyPair, SanType};
use sha2::{Digest, Sha256};

/// This project's persistent, self-signed mesh server identity — generated
/// once on first `--lan` use and reused forever. Regenerating it would
/// silently invalidate every previously-pinned client's stored fingerprint.
pub struct Identity {
    pub cert_path: PathBuf,
    pub key_path: PathBuf,
    pub fingerprint: [u8; 16],
}

pub fn tls_dir(project_root: &Path) -> PathBuf {
    project_root.join(".workbench/mesh/tls")
}

pub fn ensure_identity(project_root: &Path, lan_ips: &[String]) -> Result<Identity> {
    let dir = tls_dir(project_root);
    fs::create_dir_all(&dir).with_context(|| format!("create {}", dir.display()))?;
    let cert_path = dir.join("cert.pem");
    let key_path = dir.join("key.pem");

    if cert_path.exists() && key_path.exists() {
        let fingerprint = fingerprint_from_cert_pem(&cert_path)?;
        return Ok(Identity {
            cert_path,
            key_path,
            fingerprint,
        });
    }

    let key_pair = KeyPair::generate().context("generate TLS keypair")?;
    let mut params = CertificateParams::default();
    let mut dn = DistinguishedName::new();
    dn.push(DnType::CommonName, "workbench-mesh");
    params.distinguished_name = dn;
    params.subject_alt_names = lan_ips
        .iter()
        .filter_map(|ip| ip.parse::<IpAddr>().ok())
        .map(SanType::IpAddress)
        .collect();
    let cert = params
        .self_signed(&key_pair)
        .context("self-sign TLS certificate")?;

    let cert_pem = cert.pem();
    let key_pem = key_pair.serialize_pem();
    write_secret_pem(&cert_path, &cert_pem)?;
    write_secret_pem(&key_path, &key_pem)?;

    let digest = Sha256::digest(cert.der().as_ref());
    let fingerprint: [u8; 16] = digest[0..16].try_into().unwrap();

    Ok(Identity {
        cert_path,
        key_path,
        fingerprint,
    })
}

fn fingerprint_from_cert_pem(cert_path: &Path) -> Result<[u8; 16]> {
    let file =
        fs::File::open(cert_path).with_context(|| format!("open {}", cert_path.display()))?;
    let der = rustls_pemfile::certs(&mut BufReader::new(file))
        .next()
        .ok_or_else(|| anyhow::anyhow!("no certificate found in {}", cert_path.display()))?
        .context("parse persisted certificate")?;
    let digest = Sha256::digest(der.as_ref());
    Ok(digest[0..16].try_into().unwrap())
}

#[cfg(unix)]
fn write_secret_pem(path: &Path, contents: &str) -> Result<()> {
    use std::os::unix::fs::PermissionsExt;
    fs::write(path, contents).with_context(|| format!("write {}", path.display()))?;
    fs::set_permissions(path, fs::Permissions::from_mode(0o600))
        .with_context(|| format!("chmod {}", path.display()))?;
    Ok(())
}

#[cfg(not(unix))]
fn write_secret_pem(path: &Path, contents: &str) -> Result<()> {
    fs::write(path, contents).with_context(|| format!("write {}", path.display()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    #[test]
    fn ensure_identity_persists_and_reuses_the_same_cert() {
        let dir = TempDir::new().unwrap();
        let first = ensure_identity(dir.path(), &["127.0.0.1".to_string()]).unwrap();
        let second = ensure_identity(dir.path(), &["127.0.0.1".to_string()]).unwrap();
        assert_eq!(
            first.fingerprint, second.fingerprint,
            "cert must persist across calls, never regenerate — a changed fingerprint would break every previously-pinned client"
        );
    }

    #[test]
    fn ensure_identity_generates_files_and_a_16_byte_fingerprint() {
        let dir = TempDir::new().unwrap();
        let identity = ensure_identity(dir.path(), &["192.168.1.10".to_string()]).unwrap();
        assert!(identity.cert_path.exists());
        assert!(identity.key_path.exists());
        assert_eq!(identity.fingerprint.len(), 16);
    }

    #[cfg(unix)]
    #[test]
    fn ensure_identity_writes_key_file_with_owner_only_permissions() {
        use std::os::unix::fs::PermissionsExt;
        let dir = TempDir::new().unwrap();
        let identity = ensure_identity(dir.path(), &[]).unwrap();
        let mode = std::fs::metadata(&identity.key_path).unwrap().permissions().mode();
        assert_eq!(mode & 0o777, 0o600);
    }
}
