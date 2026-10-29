use anyhow::Result;
use clap::{Parser, Subcommand};
use multi_sync_core::Store;
use serde_json::{json, Value};
use std::{io::{Read, Write}, net::{Ipv4Addr, SocketAddr}, path::PathBuf, sync::Arc};
use multi_sync::{send, server};
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
    multi_sync::initialize_crypto();
    if let Err(error) = run(Args::parse()).await {
        emit(json!({"event":"error", "message":format!("{error:#}")}));
        std::process::exit(1);
    }
}
async fn run(args: Args) -> Result<()> {
    match args.command {
        Command::Receive { inbox, bind, advertise } => {
            let (stop, stopped) = tokio::sync::watch::channel(false);
            tokio::spawn(async move {
                #[cfg(unix)] {
                    let mut term = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate()).expect("signal handler");
                    tokio::select! { _ = tokio::signal::ctrl_c() => {}, _ = term.recv() => {} }
                }
                #[cfg(not(unix))] { let _ = tokio::signal::ctrl_c().await; }
                let _ = stop.send(true);
            });
            server::serve(inbox, bind, advertise, Arc::new(emit), stopped).await?;
        },
        Command::Send { source, journal } => {
            let ticket = if journal.exists() { None } else {
                let mut input = String::new();
                std::io::stdin().take(16385).read_to_string(&mut input)?;
                Some(input)
            };
            send::send(source, journal, ticket, Arc::new(emit)).await?;
        },
        Command::Jobs { inbox } => emit(json!({"event":"jobs", "jobs":Store::open(&inbox)?.list()?})),
        Command::Approve { inbox, id } => emit(json!({"event":"job", "job":Store::open(&inbox)?.approve(id)?})),
        Command::Reject { inbox, id } => emit(json!({"event":"job", "job":Store::open(&inbox)?.reject(id)?})),
    }
    Ok(())
}
