pub mod auth;
pub mod client;
pub mod listen;
pub mod net;
pub mod protocol;
pub mod server;
pub mod statusline;
pub mod store;
pub mod tailer;
pub mod tls;

/// Installs the process-wide rustls crypto provider before `main()` runs and
/// before any `#[test]` in this crate's test binaries runs — required
/// because this crate deliberately excludes `ring` (aws-lc-rs only), and
/// `reqwest`'s no-default-provider TLS feature panics on the first
/// `Client::new()`/`ClientBuilder::build()` call otherwise. A second call to
/// `install_default()` (e.g. if some other crate in the dependency graph
/// also tries to install one) returns `Err` rather than panicking — the
/// `let _ =` here is deliberate, not a swallowed error worth propagating.
#[ctor::ctor(unsafe)]
fn install_default_crypto_provider() {
    let _ = rustls::crypto::aws_lc_rs::default_provider().install_default();
}
