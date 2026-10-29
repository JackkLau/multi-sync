mod identity;
mod server;
mod send;

use anyhow::Result;
use clap::{Parser, Subcommand};
use multi_sync_core::Store;
use serde_json::{json, Value};
use std::{io::Write, net::{Ipv4Addr, SocketAddr}, path::PathBuf};
use uuid::Uuid;

#[derive(Parser)]
#[command(name="multi-sync", version, about="局域网文件传送；源文件始终保留")]
struct Args { #[command(subcommand)] command: Command }
#[derive(Subcommand)]
enum Command {
    Receive {
        #[arg(long)] inbox: PathBuf,
        #[arg(long, default_value="0.0.0.0:53318")] bind: SocketAddr,
        #[arg(long)] advertise: Ipv4Addr,
    },
    /// First send reads the receiving invitation from stdin; resume only needs --journal.
    Send { #[arg(long)] source: Option<PathBuf>, #[arg(long)] journal: PathBuf },
    Jobs { #[arg(long)] inbox: PathBuf },
    Approve { #[arg(long)] inbox: PathBuf, #[arg(long)] id: Uuid },
    Reject { #[arg(long)] inbox: PathBuf, #[arg(long)] id: Uuid },
}

pub fn emit(value: Value) {
    let stdout = std::io::stdout(); let mut out = stdout.lock();
    let _ = writeln!(out, "{value}"); let _ = out.flush();
}

#[tokio::main]
async fn main() {
    let _ = rustls::crypto::ring::default_provider().install_default();
    if let Err(error) = run(Args::parse()).await {
        emit(json!({"event":"error", "message":format!("{error:#}")}));
        std::process::exit(1);
    }
}
async fn run(args: Args) -> Result<()> {
    match args.command {
        Command::Receive { inbox, bind, advertise } => server::serve(inbox, bind, advertise).await?,
        Command::Send { source, journal } => send::send(source, journal).await?,
        Command::Jobs { inbox } => emit(json!({"event":"jobs", "jobs":Store::open(&inbox)?.list()?})),
        Command::Approve { inbox, id } => emit(json!({"event":"job", "job":Store::open(&inbox)?.approve(id)?})),
        Command::Reject { inbox, id } => emit(json!({"event":"job", "job":Store::open(&inbox)?.reject(id)?})),
    }
    Ok(())
}
