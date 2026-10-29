use crate::{EventSink, identity::{private_write, Ticket}};
use anyhow::{bail, ensure, Context, Result};
use multi_sync_core::{hash_bytes, hash_file, private_dir, Manifest, Transfer, CHUNK_SIZE};
use serde::{Deserialize, Serialize};
use serde_json::json;
use std::{fs::{self, File}, io::{Read, Seek, SeekFrom}, path::PathBuf, time::{Duration, Instant}};
use uuid::Uuid;

#[derive(Serialize, Deserialize)]
struct Journal { version: u8, source: PathBuf, ticket: String, manifest: Manifest }

async fn digest(path: PathBuf) -> Result<String> {
    // Hashing can take seconds. Keep the runtime responsive to pause/background signals.
    tokio::task::spawn_blocking(move || hash_file(&path)).await?
}

async fn response(response: reqwest::Response) -> Result<Transfer> {
    let status = response.status();
    let bytes = response.bytes().await?;
    if !status.is_success() {
        let value = serde_json::from_slice::<serde_json::Value>(&bytes).unwrap_or_default();
        bail!("接收方返回 {status}：{}", value.get("message").and_then(|v| v.as_str()).unwrap_or("请求未成功，请检查设备状态"));
    }
    Ok(serde_json::from_slice(&bytes)?)
}

fn check_response(job: &Transfer, manifest: &Manifest) -> Result<()> {
    ensure!(&job.manifest == manifest && job.offset <= manifest.size, "接收方返回了不一致的文件清单");
    ensure!(matches!(job.state.as_str(), "pending" | "receiving" | "committing" | "completed" | "cancelled"), "接收方任务状态无效");
    Ok(())
}

pub async fn send(source: Option<PathBuf>, journal_path: PathBuf, invitation: Option<String>, emit: EventSink) -> Result<()> {
    let journal: Journal = if journal_path.exists() {
        serde_json::from_slice(&fs::read(&journal_path)?)?
    } else {
        let source = source.context("首次发送需要 --source 文件路径")?.canonicalize()?;
        ensure!(source.is_file(), "首版仅发送普通文件，文件夹支持尚未实现");
        let name = source.file_name().and_then(|s| s.to_str()).context("文件名不是有效 UTF-8")?.to_owned();
        multi_sync_core::validate_name(&name)?;
        let input = invitation.context("首次发送需要扫描或提供接收码")?;
        let ticket = Ticket::decode(input.trim())?;
        emit(json!({"event":"hashing", "name":name}));
        let before = source.metadata()?;
        let digest = digest(source.clone()).await?;
        let after = source.metadata()?;
        ensure!(before.len() == after.len() && before.modified()? == after.modified()?, "源文件正在变化，请等写入完成后重试");
        let manifest = Manifest { id: Uuid::new_v4(), name, size: after.len(), sha256:digest };
        manifest.validate()?;
        let journal = Journal { version:1, source, ticket:ticket.encode()?, manifest };
        let parent = journal_path.parent().context("任务记录路径无效")?;
        if !parent.exists() { private_dir(parent)?; }
        ensure!(parent.is_dir(), "任务记录的父路径不是目录");
        private_write(&journal_path, &serde_json::to_vec(&journal)?)?;
        journal
    };
    ensure!(journal.version == 1, "不支持的任务记录版本");
    journal.manifest.validate()?;
    let m = &journal.manifest;
    emit(json!({"event":"hashing", "id":m.id, "name":m.name}));
    let source_meta = journal.source.metadata()?;
    ensure!(source_meta.is_file() && source_meta.len() == m.size && digest(journal.source.clone()).await? == m.sha256, "源文件已变化或无法读取；请重新选择文件建立任务");
    let ticket = Ticket::decode(&journal.ticket)?;
    let client = ticket.client()?;
    let path = format!("/v1/transfers/{}", m.id);
    let mut job = response(client.post(ticket.url("/v1/transfers")).bearer_auth(&ticket.token).json(m).send().await?).await?;
    loop {
        check_response(&job, m)?;
        if job.state != "pending" { break; }
        emit(json!({"event":"waiting", "id":m.id, "name":m.name, "size":m.size, "offset":job.offset}));
        tokio::time::sleep(Duration::from_secs(1)).await;
        job = response(client.get(ticket.url(&path)).bearer_auth(&ticket.token).send().await?).await?;
    }
    ensure!(job.state != "cancelled", "接收方已拒绝此任务，请重新发送");
    let mut source = File::open(&journal.source)?;
    let started = Instant::now(); let start_offset = job.offset;
    while job.state == "receiving" && job.offset < m.size {
        let meta = source.metadata()?;
        ensure!(meta.len() == m.size && meta.modified()? == source_meta.modified()?, "源文件在传输中变化；任务已暂停");
        source.seek(SeekFrom::Start(job.offset))?;
        let mut bytes = vec![0; (m.size - job.offset).min(CHUNK_SIZE as u64) as usize];
        source.read_exact(&mut bytes)?;
        let hash = hash_bytes(&bytes);
        let previous = job.offset;
        job = response(client.put(ticket.url(&format!("{path}/chunks?offset={previous}"))).bearer_auth(&ticket.token).header("x-chunk-sha256", hash).body(bytes).send().await?).await?;
        check_response(&job, m)?;
        ensure!(job.offset > previous, "接收方没有推进进度，请暂停后继续");
        emit(json!({"event":"progress", "id":m.id, "name":m.name, "size":m.size, "offset":job.offset, "bytes_per_second":(job.offset-start_offset) as f64 / started.elapsed().as_secs_f64().max(0.001)}));
    }
    if job.state != "completed" {
        ensure!(matches!(job.state.as_str(), "receiving" | "committing"), "接收任务已停止");
        emit(json!({"event":"verifying", "id":m.id, "name":m.name, "size":m.size, "offset":job.offset}));
        job = response(client.post(ticket.url(&format!("{path}/complete"))).bearer_auth(&ticket.token).send().await?).await?;
    }
    check_response(&job, m)?;
    ensure!(job.state == "completed" && job.offset == m.size, "接收方尚未确认完成");
    emit(json!({"event":"completed", "id":m.id, "name":m.name, "size":m.size, "offset":job.offset, "final_name":job.final_name}));
    Ok(()) // the source is only ever opened for reading
}
