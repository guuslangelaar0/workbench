use std::net::{SocketAddr, UdpSocket};
use std::process::Command;

use anyhow::{bail, Result};

pub struct BindInfo {
    pub bind_addr: SocketAddr,
    pub mode: String,
    pub hostname: String,
    pub mdns_name: String,
    pub lan_ips: Vec<String>,
}

pub fn detect_bind(mode: &str, port: u16) -> Result<BindInfo> {
    let bind_addr = match mode {
        "local" => SocketAddr::from(([127, 0, 0, 1], port)),
        "lan" => SocketAddr::from(([0, 0, 0, 0], port)),
        other => bail!("unsupported bind mode: {other}"),
    };
    let hostname = detect_hostname();
    let mdns_name = format!("{}.local", hostname.replace(' ', "-"));
    let lan_ips = detect_lan_ips();

    Ok(BindInfo {
        bind_addr,
        mode: mode.to_string(),
        hostname,
        mdns_name,
        lan_ips,
    })
}

fn detect_hostname() -> String {
    if let Ok(output) = Command::new("hostname").output() {
        if output.status.success() {
            let hostname = String::from_utf8_lossy(&output.stdout).trim().to_string();
            if !hostname.is_empty() {
                return hostname;
            }
        }
    }
    std::env::var("HOSTNAME")
        .ok()
        .filter(|value| !value.trim().is_empty())
        .unwrap_or_else(|| "workbench".to_string())
}

fn detect_lan_ips() -> Vec<String> {
    let Ok(socket) = UdpSocket::bind("0.0.0.0:0") else {
        return Vec::new();
    };
    if socket.connect("8.8.8.8:80").is_err() {
        return Vec::new();
    }
    let Ok(addr) = socket.local_addr() else {
        return Vec::new();
    };
    let ip = addr.ip();
    if ip.is_loopback() {
        Vec::new()
    } else {
        vec![ip.to_string()]
    }
}
