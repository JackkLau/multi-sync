mod store;

pub use store::Store;
use anyhow::{bail, ensure, Result};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{fs::File, io::Read, path::Path};
use uuid::Uuid;

pub const CHUNK_SIZE: usize = 1024 * 1024;
pub const MAX_FILE_SIZE: u64 = 1024 * 1024 * 1024 * 1024;

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct Manifest {
    pub id: Uuid,
    pub name: String,
    pub size: u64,
    pub sha256: String,
}

impl Manifest {
    pub fn validate(&self) -> Result<()> {
        validate_name(&self.name)?;
        ensure!(self.size <= MAX_FILE_SIZE, "文件超过首版 1 TiB 上限");
        ensure!(valid_hash(&self.sha256), "无效的 SHA-256");
        Ok(())
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Transfer {
    #[serde(flatten)]
    pub manifest: Manifest,
    pub offset: u64,
    pub state: String,
    pub final_name: Option<String>,
}

pub fn valid_hash(value: &str) -> bool {
    value.len() == 64 && value.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

/// A deliberately portable leaf name. Never turn a remote path into a local path.
pub fn validate_name(name: &str) -> Result<()> {
    ensure!(!name.is_empty() && name.len() <= 180, "文件名须为 1–180 个 UTF-8 字节");
    ensure!(!matches!(name, "." | ".."), "无效的文件名");
    ensure!(!name.ends_with('.') && !name.ends_with(' '), "文件名不能以句点或空格结尾");
    ensure!(!name.chars().any(|c| c.is_control() || "<>:\"/\\|?*".contains(c)), "文件名包含跨平台不支持的字符");
    let stem = name.split('.').next().unwrap_or("").trim_end_matches(' ').to_ascii_uppercase();
    if matches!(stem.as_str(), "CON" | "PRN" | "AUX" | "NUL")
        || ["COM", "LPT"].iter().any(|p| stem.strip_prefix(*p).is_some_and(|s| {
            matches!(s, "1" | "2" | "3" | "4" | "5" | "6" | "7" | "8" | "9" | "¹" | "²" | "³")
        }))
        || name.eq_ignore_ascii_case(".multisync")
    {
        bail!("文件名为系统保留名称");
    }
    Ok(())
}

pub fn hash_bytes(bytes: &[u8]) -> String { format!("{:x}", Sha256::digest(bytes)) }

pub fn hash_file(path: &Path) -> Result<String> {
    let mut input = File::open(path)?;
    let mut hash = Sha256::new();
    let mut buffer = vec![0u8; CHUNK_SIZE];
    loop {
        let count = input.read(&mut buffer)?;
        if count == 0 { break; }
        hash.update(&buffer[..count]);
    }
    Ok(format!("{:x}", hash.finalize()))
}

pub fn private_dir(path: &Path) -> Result<()> {
    if let Ok(meta) = std::fs::symlink_metadata(path) {
        ensure!(meta.is_dir() && !meta.file_type().is_symlink(), "状态目录不能为符号链接或普通文件");
    }
    std::fs::create_dir_all(path)?;
    #[cfg(unix)] {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o700))?;
    }
    Ok(())
}

