use crate::{hash_bytes, hash_file, private_dir, publish_new, Manifest, Transfer, CHUNK_SIZE};
use anyhow::{bail, ensure, Context, Result};
use rusqlite::{params, Connection, OptionalExtension, TransactionBehavior};
use std::{fs::{self, File, OpenOptions}, io::{Read, Seek, SeekFrom, Write}, path::{Path, PathBuf}, time::Duration};
use uuid::Uuid;

pub struct Store { conn: Connection, root: PathBuf, state: PathBuf }

fn read_transfer(row: &rusqlite::Row<'_>) -> rusqlite::Result<Transfer> {
    let id: String = row.get(0)?;
    let id = Uuid::parse_str(&id).map_err(|e| rusqlite::Error::FromSqlConversionFailure(0, rusqlite::types::Type::Text, Box::new(e)))?;
    Ok(Transfer {
        manifest: Manifest { id, name: row.get(1)?, size: row.get(2)?, sha256: row.get(3)? },
        offset: row.get(4)?, state: row.get(5)?, final_name: row.get(6)?,
    })
}

fn fetch(conn: &Connection, id: Uuid) -> Result<Transfer> {
    Ok(conn.query_row("SELECT id,name,size,sha256,offset,state,final_name FROM transfers WHERE id=?1", [id.to_string()], read_transfer)?)
}

fn regular_file(path: &Path) -> Result<File> {
    let meta = fs::symlink_metadata(path)?;
    ensure!(meta.is_file() && !meta.file_type().is_symlink(), "临时文件不再是普通文件");
    Ok(OpenOptions::new().read(true).write(true).open(path)?)
}

#[cfg(unix)]
fn sync_directory(path: &Path) -> Result<()> { File::open(path)?.sync_all()?; Ok(()) }
#[cfg(not(unix))]
fn sync_directory(_: &Path) -> Result<()> { Ok(()) }

impl Store {
    pub fn open(root: &Path) -> Result<Self> {
        fs::create_dir_all(root)?;
        let root = root.canonicalize()?;
        let state = root.join(".multisync");
        private_dir(&state)?;
        let db = state.join("tasks.sqlite3");
        if let Ok(meta) = fs::symlink_metadata(&db) { ensure!(meta.is_file() && !meta.file_type().is_symlink(), "任务数据库不能为符号链接"); }
        let conn = Connection::open(db)?;
        conn.busy_timeout(Duration::from_secs(10))?;
        conn.execute_batch("PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL;")?;
        let version: i32 = conn.query_row("PRAGMA user_version", [], |r| r.get(0))?;
        ensure!(version <= 1, "任务数据库由更新版本创建，请升级应用");
        conn.execute_batch("CREATE TABLE IF NOT EXISTS transfers (
            id TEXT PRIMARY KEY, name TEXT NOT NULL, size INTEGER NOT NULL CHECK(size>=0),
            sha256 TEXT NOT NULL, offset INTEGER NOT NULL DEFAULT 0 CHECK(offset>=0 AND offset<=size),
            state TEXT NOT NULL CHECK(state IN ('pending','receiving','committing','completed','cancelled')),
            final_name TEXT UNIQUE, created_at INTEGER NOT NULL DEFAULT(unixepoch())
        ); PRAGMA user_version=1;")?;
        Ok(Self { conn, root, state })
    }

    pub fn state_dir(&self) -> &Path { &self.state }
    pub fn get(&self, id: Uuid) -> Result<Transfer> { fetch(&self.conn, id) }
    pub fn list(&self) -> Result<Vec<Transfer>> {
        let mut stmt = self.conn.prepare("SELECT id,name,size,sha256,offset,state,final_name FROM transfers ORDER BY created_at DESC, rowid DESC")?;
        let rows = stmt.query_map([], read_transfer)?;
        Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
    }

    pub fn offer(&mut self, manifest: &Manifest) -> Result<Transfer> {
        manifest.validate()?;
        let tx = self.conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let existing = tx.query_row("SELECT id,name,size,sha256,offset,state,final_name FROM transfers WHERE id=?1", [manifest.id.to_string()], read_transfer).optional()?;
        if let Some(existing) = existing {
            ensure!(existing.manifest == *manifest, "任务 ID 已存在，文件清单不一致");
            return Ok(existing);
        }
        let active: i64 = tx.query_row("SELECT COUNT(*) FROM transfers WHERE state NOT IN ('completed','cancelled')", [], |r| r.get(0))?;
        ensure!(active < 128, "接收队列已满，请先处理已有任务");
        ensure!(fs2::available_space(&self.root)? >= manifest.size.saturating_add(CHUNK_SIZE as u64), "接收磁盘空间不足");
        tx.execute("INSERT INTO transfers(id,name,size,sha256,state) VALUES(?1,?2,?3,?4,'pending')", params![manifest.id.to_string(), manifest.name, manifest.size, manifest.sha256])?;
        tx.commit()?;
        self.get(manifest.id)
    }

    pub fn approve(&mut self, id: Uuid) -> Result<Transfer> {
        let tx = self.conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let job = fetch(&tx, id)?;
        if job.state == "receiving" { return Ok(job); }
        ensure!(job.state == "pending", "该任务无法接受");
        let part = self.state.join(format!("{id}.part"));
        // An orphan after a crash before DB commit contains no acknowledged bytes.
        if part.exists() { regular_file(&part)?.set_len(0)?; }
        else { OpenOptions::new().write(true).create_new(true).open(&part)?.sync_all()?; }
        sync_directory(&self.state)?;
        tx.execute("UPDATE transfers SET state='receiving' WHERE id=?1", [id.to_string()])?;
        tx.commit()?;
        self.get(id)
    }

    pub fn reject(&mut self, id: Uuid) -> Result<Transfer> {
        let tx = self.conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let job = fetch(&tx, id)?;
        ensure!(matches!(job.state.as_str(), "pending" | "receiving" | "cancelled"), "文件正在提交或已经完成，无法拒绝");
        tx.execute("UPDATE transfers SET state='cancelled' WHERE id=?1", [id.to_string()])?;
        tx.commit()?;
        self.get(id)
    }

    pub fn chunk(&mut self, id: Uuid, offset: u64, bytes: &[u8], digest: &str) -> Result<Transfer> {
        ensure!(!bytes.is_empty() && bytes.len() <= CHUNK_SIZE, "数据块长度无效");
        ensure!(hash_bytes(bytes) == digest, "数据块校验失败，请重试");
        let tx = self.conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let job = fetch(&tx, id)?;
        ensure!(job.state == "receiving", "接收方尚未接受，或任务已结束");
        let end = offset.checked_add(bytes.len() as u64).context("偏移溢出")?;
        ensure!(end <= job.manifest.size, "数据超过声明的文件大小");
        let mut file = regular_file(&self.state.join(format!("{id}.part")))?;
        ensure!(file.metadata()?.len() >= job.offset, "临时文件损坏，已确认的数据丢失");
        file.set_len(job.offset)?; // discard only unacknowledged tail from an interrupted write
        if offset < job.offset && end <= job.offset {
            let mut previous = vec![0; bytes.len()];
            file.seek(SeekFrom::Start(offset))?; file.read_exact(&mut previous)?;
            ensure!(previous == bytes, "重复数据块内容不一致");
            return Ok(job);
        }
        ensure!(offset == job.offset, "偏移不一致，请查询任务并恢复");
        ensure!(fs2::available_space(&self.root)? >= bytes.len() as u64 + CHUNK_SIZE as u64, "接收磁盘空间不足");
        file.seek(SeekFrom::Start(offset))?; file.write_all(bytes)?; file.sync_all()?;
        tx.execute("UPDATE transfers SET offset=?2 WHERE id=?1", params![id.to_string(), end])?;
        tx.commit()?; // acknowledge only after file data and SQLite checkpoint are durable
        self.get(id)
    }

    pub fn complete(&mut self, id: Uuid) -> Result<Transfer> {
        let part = self.state.join(format!("{id}.part"));
        let tx = self.conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let job = fetch(&tx, id)?;
        if job.state == "completed" { return Ok(job); }
        ensure!(matches!(job.state.as_str(), "receiving" | "committing"), "任务无法提交");
        ensure!(job.offset == job.manifest.size, "文件尚未接收完整");
        // A no-replace rename can finish before the completed checkpoint is committed.
        // Recover only the reserved, fully verified destination; a missing partial alone
        // is never evidence of success.
        if job.state == "committing" && matches!(fs::symlink_metadata(&part), Err(ref e) if e.kind() == std::io::ErrorKind::NotFound) {
            let name = job.final_name.as_ref().context("提交任务缺少目标文件名")?;
            let destination = self.root.join(name);
            let meta = fs::symlink_metadata(&destination).context("提交文件丢失，保留任务等待恢复")?;
            ensure!(meta.is_file() && !meta.file_type().is_symlink() && meta.len() == job.manifest.size
                && hash_file(&destination)? == job.manifest.sha256, "提交文件不完整或已被修改，未确认完成");
            sync_directory(&self.root)?;
            sync_directory(&self.state)?;
            tx.execute("UPDATE transfers SET state='completed' WHERE id=?1", [id.to_string()])?;
            tx.commit()?;
            return self.get(id);
        }
        let file = regular_file(&part)?;
        ensure!(file.metadata()?.len() >= job.offset, "临时文件损坏");
        file.set_len(job.offset)?; file.sync_all()?;
        if hash_file(&part)? != job.manifest.sha256 {
            // Commit the reset first: a crash can leave a tail, never a checkpoint beyond EOF.
            tx.execute("UPDATE transfers SET offset=0,state='receiving',final_name=NULL WHERE id=?1", [id.to_string()])?;
            tx.commit()?;
            file.set_len(0)?; file.sync_all()?;
            bail!("文件完整性校验失败；再次继续将从头传输");
        }
        let final_name = match job.final_name {
            Some(name) => name,
            None => {
                let mut candidate = job.manifest.name.clone();
                let path = Path::new(&job.manifest.name);
                let stem = path.file_stem().and_then(|x| x.to_str()).unwrap_or("file");
                let extension = path.extension().and_then(|x| x.to_str()).map(|x| format!(".{x}")).unwrap_or_default();
                let mut suffix = 0u32;
                loop {
                    let reserved: bool = tx.query_row("SELECT EXISTS(SELECT 1 FROM transfers WHERE final_name=?1)", [&candidate], |r| r.get(0))?;
                    if fs::symlink_metadata(self.root.join(&candidate)).is_err() && !reserved { break; }
                    suffix += 1;
                    ensure!(suffix <= 10000, "无法分配接收文件名");
                    candidate = format!("{stem} ({id}-{suffix}){extension}");
                }
                candidate
            }
        };
        tx.execute("UPDATE transfers SET state='committing',final_name=?2 WHERE id=?1", params![id.to_string(), final_name])?;
        tx.commit()?;
        let destination = self.root.join(&final_name);
        match publish_new(&part, &destination) {
            Ok(()) => {},
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {
                let meta = fs::symlink_metadata(&destination)?;
                ensure!(meta.is_file() && !meta.file_type().is_symlink() && hash_file(&destination)? == job.manifest.sha256,
                    "提交位置被其他文件占用，请移走该文件后重试；现有文件未被覆盖");
            },
            Err(e) => return Err(e).context("无法原子提交文件，接收位置需支持不覆盖的原子提交"),
        }
        sync_directory(&self.root)?;
        sync_directory(&self.state)?;
        self.conn.execute("UPDATE transfers SET state='completed' WHERE id=?1", [id.to_string()])?;
        // Failure to clean a private partial does not turn successful delivery into a failure.
        let _ = fs::remove_file(part);
        let _ = sync_directory(&self.state);
        self.get(id)
    }
}
