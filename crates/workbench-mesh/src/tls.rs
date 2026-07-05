use std::fs;
use std::fs::OpenOptions;
use std::io::BufReader;
use std::net::IpAddr;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use anyhow::{Context, Result};
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use base64::Engine;
use fs2::FileExt;
use rcgen::{CertificateParams, DistinguishedName, DnType, KeyPair, SanType};
use rustls::client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier};
use rustls::crypto::{verify_tls12_signature, verify_tls13_signature, CryptoProvider};
use rustls::pki_types::{CertificateDer, ServerName, UnixTime};
use rustls::{DigitallySignedStruct, SignatureScheme};
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

pub fn server_config_from_identity(identity: &Identity) -> Result<rustls::ServerConfig> {
    let cert_file = fs::File::open(&identity.cert_path)
        .with_context(|| format!("open {}", identity.cert_path.display()))?;
    let certs: Vec<CertificateDer<'static>> = rustls_pemfile::certs(&mut BufReader::new(cert_file))
        .collect::<std::result::Result<_, _>>()
        .with_context(|| format!("parse {}", identity.cert_path.display()))?;

    let key_file = fs::File::open(&identity.key_path)
        .with_context(|| format!("open {}", identity.key_path.display()))?;
    let key = rustls_pemfile::private_key(&mut BufReader::new(key_file))
        .with_context(|| format!("parse {}", identity.key_path.display()))?
        .ok_or_else(|| anyhow::anyhow!("no private key found in {}", identity.key_path.display()))?;

    let provider = Arc::new(rustls::crypto::aws_lc_rs::default_provider());
    let mut config = rustls::ServerConfig::builder_with_provider(provider)
        .with_protocol_versions(&[&rustls::version::TLS13])
        .expect("TLS 1.3 is supported by the aws-lc-rs provider")
        .with_no_client_auth()
        .with_single_cert(certs, key)
        .context("build TLS server config from persisted identity")?;
    config.alpn_protocols = vec![b"http/1.1".to_vec()];
    Ok(config)
}

#[derive(Debug)]
struct PinnedCertVerifier {
    pinned: [u8; 16],
    provider: Arc<CryptoProvider>,
}

impl ServerCertVerifier for PinnedCertVerifier {
    fn verify_server_cert(
        &self,
        end_entity: &CertificateDer<'_>,
        _intermediates: &[CertificateDer<'_>],
        _server_name: &ServerName<'_>,
        _ocsp_response: &[u8],
        _now: UnixTime,
    ) -> Result<ServerCertVerified, rustls::Error> {
        let digest = Sha256::digest(end_entity.as_ref());
        let actual: [u8; 16] = digest[0..16].try_into().unwrap();
        if actual == self.pinned {
            Ok(ServerCertVerified::assertion())
        } else {
            // This is the entire security boundary. There is no fallback to
            // CA/webpki validation under any circumstance — a mismatch is
            // always a hard failure, never a warning.
            Err(rustls::Error::InvalidCertificate(
                rustls::CertificateError::ApplicationVerificationFailure,
            ))
        }
    }

    // These MUST delegate to the provider's real signature verification, not
    // stub "valid" — a stub here would let a MITM replay the pinned cert's
    // bytes (passing verify_server_cert) while forging the handshake
    // signature, making the pin purely decorative.
    fn verify_tls12_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        verify_tls12_signature(message, cert, dss, &self.provider.signature_verification_algorithms)
    }

    fn verify_tls13_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        verify_tls13_signature(message, cert, dss, &self.provider.signature_verification_algorithms)
    }

    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        self.provider.signature_verification_algorithms.supported_schemes()
    }
}

/// Builds a rustls ClientConfig that trusts exactly one certificate — the one
/// whose truncated SHA-256 fingerprint matches `pinned` — via aws-lc-rs,
/// TLS 1.3 only. No CA, no webpki root store, no fallback path.
pub fn pinned_client_config(pinned: [u8; 16]) -> rustls::ClientConfig {
    let provider = Arc::new(rustls::crypto::aws_lc_rs::default_provider());
    let verifier = PinnedCertVerifier {
        pinned,
        provider: provider.clone(),
    };
    rustls::ClientConfig::builder_with_provider(provider)
        .with_protocol_versions(&[&rustls::version::TLS13])
        .expect("TLS 1.3 is supported by the aws-lc-rs provider")
        .dangerous()
        .with_custom_certificate_verifier(Arc::new(verifier))
        .with_no_client_auth()
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

    #[test]
    fn server_config_from_identity_builds_a_tls13_only_config() {
        let dir = TempDir::new().unwrap();
        let identity = ensure_identity(dir.path(), &["127.0.0.1".to_string()]).unwrap();
        let config = server_config_from_identity(&identity).unwrap();
        assert_eq!(config.alpn_protocols, vec![b"http/1.1".to_vec()]);
    }

    #[tokio::test]
    async fn pinned_client_config_accepts_a_matching_certificate() {
        let dir = TempDir::new().unwrap();
        let identity = ensure_identity(dir.path(), &["127.0.0.1".to_string()]).unwrap();
        let server_config = server_config_from_identity(&identity).unwrap();
        let (addr, _server) = spawn_test_tls_echo_server(server_config).await;

        let client_config = pinned_client_config(identity.fingerprint);
        let outcome = tls_connect_and_read_one_byte(addr, client_config).await;
        assert!(outcome.is_ok(), "a correct pin must allow the handshake to succeed");
    }

    #[tokio::test]
    async fn pinned_client_config_rejects_a_wrong_fingerprint() {
        let dir = TempDir::new().unwrap();
        let identity = ensure_identity(dir.path(), &["127.0.0.1".to_string()]).unwrap();
        let server_config = server_config_from_identity(&identity).unwrap();
        let (addr, _server) = spawn_test_tls_echo_server(server_config).await;

        let wrong_pin = [identity.fingerprint[0] ^ 0xFF; 16];
        let client_config = pinned_client_config(wrong_pin);
        let outcome = tls_connect_and_read_one_byte(addr, client_config).await;
        assert!(
            outcome.is_err(),
            "THE load-bearing test of this whole feature: a wrong fingerprint MUST hard-fail the handshake, never silently succeed"
        );
        // Guard against this test "passing" for an unrelated reason (e.g. a
        // TCP setup error): the failure must be a certificate rejection from
        // the TLS layer itself, not some incidental I/O problem.
        let message = format!("{:#}", outcome.unwrap_err()).to_lowercase();
        assert!(
            message.contains("certificate"),
            "handshake must fail specifically at certificate verification, got: {message}"
        );
    }

    // --- test-only helpers, real TLS over a real loopback socket, no mocks ---

    async fn spawn_test_tls_echo_server(
        config: rustls::ServerConfig,
    ) -> (std::net::SocketAddr, tokio::task::JoinHandle<()>) {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let acceptor = tokio_rustls::TlsAcceptor::from(std::sync::Arc::new(config));
        let handle = tokio::spawn(async move {
            if let Ok((stream, _)) = listener.accept().await {
                if let Ok(mut tls) = acceptor.accept(stream).await {
                    let mut buf = [0u8; 1];
                    let _ = tls.read_exact(&mut buf).await;
                    let _ = tls.write_all(&[42u8]).await;
                }
            }
        });
        (addr, handle)
    }

    async fn tls_connect_and_read_one_byte(
        addr: std::net::SocketAddr,
        client_config: rustls::ClientConfig,
    ) -> Result<()> {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        let connector = tokio_rustls::TlsConnector::from(std::sync::Arc::new(client_config));
        let tcp = tokio::net::TcpStream::connect(addr).await?;
        let server_name = rustls::pki_types::ServerName::IpAddress(addr.ip().into());
        let mut tls = connector.connect(server_name, tcp).await?;
        tls.write_all(&[1u8]).await?;
        let mut buf = [0u8; 1];
        tls.read_exact(&mut buf).await?;
        Ok(())
    }
}
