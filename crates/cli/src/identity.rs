use anyhow::{ensure, Result};
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};
use serde::{Deserialize, Serialize};
use std::{fs::{self, OpenOptions}, io::Write, net::Ipv4Addr, path::Path};
use uuid::Uuid;

#[derive(Serialize, Deserialize)]
pub struct Identity { pub cert_pem: String, pub key_pem: String, pub cert_der: String, pub token: String }

pub fn private_write(path: &Path, bytes: &[u8]) -> Result<()> {
    let temp = path.with_extension(format!("{}.new", Uuid::new_v4()));
    let mut options = OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)] { use std::os::unix::fs::OpenOptionsExt; options.mode(0o600); }
    let mut file = options.open(&temp)?;
    file.write_all(bytes)?; file.sync_all()?; drop(file);
    // Callers use new UUID paths or hold the receiver lock; never overwrite a journal.
    multi_sync_core::publish_new(&temp, path)?;
    match fs::remove_file(temp) {
        Ok(()) => {},
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}, // moved by atomic publication
        Err(error) => return Err(error.into()),
    }
    #[cfg(unix)] { std::fs::File::open(path.parent().unwrap())?.sync_all()?; }
    Ok(())
}

impl Identity {
    pub fn load_or_create(directory: &Path) -> Result<Self> {
        let path = directory.join("identity.json");
        if path.exists() { return Ok(serde_json::from_slice(&fs::read(path)?)?); }
        let certified = rcgen::generate_simple_self_signed(vec!["multi-sync.local".into()])?;
        let identity = Self {
            cert_pem: certified.cert.pem(), key_pem: certified.key_pair.serialize_pem(),
            cert_der: URL_SAFE_NO_PAD.encode(certified.cert.der()),
            token: format!("{}{}", Uuid::new_v4().simple(), Uuid::new_v4().simple()),
        };
        private_write(&path, &serde_json::to_vec(&identity)?)?;
        Ok(identity)
    }

    pub fn ticket(&self, host: Ipv4Addr, port: u16) -> Result<String> {
        Ticket { version: 1, host, port, certificate: self.cert_der.clone(), token: self.token.clone() }.encode()
    }
    pub fn fingerprint(&self) -> Result<String> {
        Ok(multi_sync_core::hash_bytes(&URL_SAFE_NO_PAD.decode(&self.cert_der)?))
    }
}

#[derive(Clone, Serialize, Deserialize)]
pub struct Ticket { pub version: u8, pub host: Ipv4Addr, pub port: u16, pub certificate: String, pub token: String }

pub fn local_address(host: Ipv4Addr) -> bool { host.is_private() || host.is_loopback() || host.is_link_local() }

impl Ticket {
    pub fn encode(&self) -> Result<String> { Ok(format!("msync1:{}", URL_SAFE_NO_PAD.encode(serde_json::to_vec(self)?))) }
    pub fn decode(value: &str) -> Result<Self> {
        ensure!(value.len() <= 16384, "接收邀请过长");
        let payload = value.trim().strip_prefix("msync1:").ok_or_else(|| anyhow::anyhow!("接收邀请格式错误"))?;
        let ticket: Self = serde_json::from_slice(&URL_SAFE_NO_PAD.decode(payload)?)?;
        ensure!(ticket.version == 1 && ticket.port != 0 && local_address(ticket.host), "首版仅支持本地 IPv4 地址");
        ensure!(ticket.token.len() == 64 && ticket.token.bytes().all(|b| b.is_ascii_hexdigit()), "接收邀请密钥无效");
        Ok(ticket)
    }
    pub fn client(&self) -> Result<reqwest::Client> {
        let cert = reqwest::Certificate::from_der(&URL_SAFE_NO_PAD.decode(&self.certificate)?)?;
        Ok(reqwest::Client::builder().use_rustls_tls()
            .tls_built_in_root_certs(false).add_root_certificate(cert)
            .resolve("multi-sync.local", std::net::SocketAddr::from((self.host, self.port)))
            .no_proxy().redirect(reqwest::redirect::Policy::none())
            .connect_timeout(std::time::Duration::from_secs(10))
            .timeout(std::time::Duration::from_secs(120)).build()?)
    }
    pub fn url(&self, path: &str) -> String { format!("https://multi-sync.local:{}{path}", self.port) }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn no_public_or_unspecified_destination() {
        for address in ["8.8.8.8", "0.0.0.0", "224.0.0.1"] { assert!(!local_address(address.parse().unwrap())); }
        for address in ["192.168.1.3", "10.0.0.2", "172.16.0.8", "127.0.0.1"] { assert!(local_address(address.parse().unwrap())); }
        assert!(Ticket::decode("http://example.org").is_err());
    }
}
