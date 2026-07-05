use std::fs;
use std::fs::OpenOptions;
use std::io::BufReader;
use std::net::IpAddr;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result};
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use base64::Engine;
use fs2::FileExt;
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

    // Serialize check-then-generate under a dedicated lock file so two
    // concurrent processes cannot both take the generation branch. We cannot
    // lock cert.pem itself: creating it would break the existence check.
    let lock_path = dir.join("identity.lock");
    let lock_file = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .open(&lock_path)
        .with_context(|| format!("open {}", lock_path.display()))?;
    lock_file
        .lock_exclusive()
        .with_context(|| format!("lock {}", lock_path.display()))?;
    let result = (|| {
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
    })();
    lock_file
        .unlock()
        .with_context(|| format!("unlock {}", lock_path.display()))?;
    result
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

pub fn encode_fingerprint(fp: &[u8; 16]) -> String {
    URL_SAFE_NO_PAD.encode(fp)
}

pub fn decode_fingerprint(s: &str) -> Result<[u8; 16]> {
    let raw = s.strip_prefix("sha256:").unwrap_or(s);
    let bytes = URL_SAFE_NO_PAD
        .decode(raw)
        .context("fingerprint is not valid base64url")?;
    bytes
        .try_into()
        .map_err(|_| anyhow::anyhow!("fingerprint must decode to exactly 16 bytes"))
}

/// Derived from the same pinned fingerprint bytes the crypto layer already
/// enforces — this is a human cross-check against a *tampered invite string*,
/// not a re-verification of what the TLS handshake already proved.
pub fn human_code(fp: &[u8; 16]) -> String {
    let n = u32::from_be_bytes([fp[0], fp[1], fp[2], fp[3]]) % 1_000_000;
    format!("{:03}-{:03}", n / 1000, n % 1000)
}

#[cfg(unix)]
fn write_secret_pem(path: &Path, contents: &str) -> Result<()> {
    use std::io::Write;
    use std::os::unix::fs::OpenOptionsExt;
    let mut file = fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o600)
        .open(path)
        .with_context(|| format!("open {}", path.display()))?;
    file.write_all(contents.as_bytes())
        .with_context(|| format!("write {}", path.display()))?;
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

    #[test]
    fn concurrent_ensure_identity_calls_agree_on_one_fingerprint() {
        use std::sync::{Arc, Barrier};
        let dir = TempDir::new().unwrap();
        let root = Arc::new(dir.path().to_path_buf());
        let barrier = Arc::new(Barrier::new(4));
        let handles: Vec<_> = (0..4)
            .map(|_| {
                let root = Arc::clone(&root);
                let barrier = Arc::clone(&barrier);
                std::thread::spawn(move || {
                    barrier.wait();
                    ensure_identity(&root, &["127.0.0.1".to_string()]).unwrap().fingerprint
                })
            })
            .collect();
        let fingerprints: Vec<[u8; 16]> = handles.into_iter().map(|h| h.join().unwrap()).collect();
        // All racers must agree: exactly one generated, the rest reused its result.
        assert!(
            fingerprints.windows(2).all(|w| w[0] == w[1]),
            "concurrent ensure_identity produced divergent fingerprints: {fingerprints:?}"
        );
        // And what survives on disk must match what every caller believes.
        let on_disk = fingerprint_from_cert_pem(&tls_dir(&root).join("cert.pem")).unwrap();
        assert_eq!(fingerprints[0], on_disk, "in-memory fingerprint diverged from persisted cert");
    }

    #[test]
    fn encode_decode_fingerprint_round_trips_with_and_without_prefix() {
        let fp = [7u8; 16];
        let encoded = encode_fingerprint(&fp);
        assert_eq!(decode_fingerprint(&encoded).unwrap(), fp);
        assert_eq!(decode_fingerprint(&format!("sha256:{encoded}")).unwrap(), fp);
    }

    #[test]
    fn decode_fingerprint_rejects_garbage() {
        assert!(decode_fingerprint("not-base64!!").is_err());
        assert!(decode_fingerprint("sha256:dGVzdA").is_err(), "4-byte decode must not silently accept a wrong-length fingerprint");
    }

    #[test]
    fn human_code_is_six_digits_dash_formatted_and_deterministic() {
        let fp = [42u8; 16];
        let code = human_code(&fp);
        assert_eq!(code.len(), 7, "expected NNN-NNN (7 chars)");
        assert_eq!(code.chars().nth(3), Some('-'));
        assert_eq!(human_code(&fp), code, "must be deterministic for the same fingerprint");
    }

    #[test]
    fn human_code_differs_for_different_fingerprints() {
        assert_ne!(human_code(&[1u8; 16]), human_code(&[2u8; 16]));
    }
}
