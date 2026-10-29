use crate::{EventSink, identity::{local_address, Identity}};
use anyhow::{ensure, Result};
use axum::{body::Bytes, extract::{DefaultBodyLimit, Path, Query, State}, http::{HeaderMap, StatusCode}, response::{IntoResponse, Response}, routing::{get, post, put}, Json, Router};
use multi_sync_core::{Store, Transfer, Manifest, CHUNK_SIZE};
use serde::Deserialize;
use serde_json::json;
use std::{fs::OpenOptions, net::{Ipv4Addr, SocketAddr}, path::PathBuf, sync::{Arc, Mutex}};
use subtle::ConstantTimeEq;
use uuid::Uuid;

#[derive(Clone)]
struct AppState { store: Arc<Mutex<Store>>, token: String }
struct ApiError(StatusCode, String);
impl IntoResponse for ApiError {
    fn into_response(self) -> Response { (self.0, Json(json!({"message": self.1}))).into_response() }
}
type ApiResult = std::result::Result<Json<Transfer>, ApiError>;

fn authorize(headers: &HeaderMap, state: &AppState) -> std::result::Result<(), ApiError> {
    let provided = headers.get("authorization").and_then(|s| s.to_str().ok()).and_then(|s| s.strip_prefix("Bearer ")).unwrap_or("");
    if provided.as_bytes().ct_eq(state.token.as_bytes()).into() { Ok(()) }
    else { Err(ApiError(StatusCode::UNAUTHORIZED, "接收邀请不匹配".into())) }
}

async fn execute(state: AppState, f: impl FnOnce(&mut Store) -> Result<Transfer> + Send + 'static) -> ApiResult {
    tokio::task::spawn_blocking(move || {
        let mut store = state.store.lock().map_err(|_| ApiError(StatusCode::INTERNAL_SERVER_ERROR, "任务数据库不可用".into()))?;
        f(&mut store).map(Json).map_err(|e| ApiError(StatusCode::CONFLICT, e.to_string()))
    }).await.map_err(|_| ApiError(StatusCode::INTERNAL_SERVER_ERROR, "接收处理失败".into()))?
}

async fn offer(State(state): State<AppState>, headers: HeaderMap, Json(manifest): Json<Manifest>) -> ApiResult {
    authorize(&headers, &state)?;
    execute(state, move |store| store.offer(&manifest)).await
}
async fn status(State(state): State<AppState>, Path(id): Path<Uuid>, headers: HeaderMap) -> ApiResult {
    authorize(&headers, &state)?;
    execute(state, move |store| store.get(id)).await
}
#[derive(Deserialize)]
struct ChunkQuery { offset: u64 }
async fn chunk(State(state): State<AppState>, Path(id): Path<Uuid>, Query(query): Query<ChunkQuery>, headers: HeaderMap, body: Bytes) -> ApiResult {
    authorize(&headers, &state)?;
    let hash = headers.get("x-chunk-sha256").and_then(|s| s.to_str().ok()).unwrap_or("").to_owned();
    execute(state, move |store| store.chunk(id, query.offset, &body, &hash)).await
}
async fn complete(State(state): State<AppState>, Path(id): Path<Uuid>, headers: HeaderMap) -> ApiResult {
    authorize(&headers, &state)?;
    execute(state, move |store| store.complete(id)).await
}

pub async fn serve(inbox: PathBuf, bind: SocketAddr, advertise: Ipv4Addr, emit: EventSink, mut stopped: tokio::sync::watch::Receiver<bool>) -> Result<()> {
    ensure!(local_address(advertise), "公布地址必须是局域网 IPv4 地址");
    ensure!(bind.is_ipv4() && (bind.ip().is_unspecified() || match bind.ip() { std::net::IpAddr::V4(ip) => local_address(ip), _ => false }), "监听地址无效");
    let store = Store::open(&inbox)?;
    let lock = OpenOptions::new().create(true).truncate(false).write(true).open(store.state_dir().join("receiver.lock"))?;
    fs2::FileExt::try_lock_exclusive(&lock).map_err(|_| anyhow::anyhow!("此接收目录已有服务运行"))?;
    let identity = Identity::load_or_create(store.state_dir())?;
    let config = axum_server::tls_rustls::RustlsConfig::from_pem(identity.cert_pem.clone().into_bytes(), identity.key_pem.clone().into_bytes()).await?;
    let listener = std::net::TcpListener::bind(bind)?;
    // axum-server 0.8 hands this socket to Tokio without changing its mode.
    // A blocking accept can stall keep-alive requests and graceful shutdown.
    listener.set_nonblocking(true)?;
    let port = listener.local_addr()?.port();
    let state = AppState { store: Arc::new(Mutex::new(store)), token: identity.token.clone() };
    let app = Router::new().route("/v1/transfers", post(offer))
        .route("/v1/transfers/{id}", get(status))
        .route("/v1/transfers/{id}/chunks", put(chunk))
        .route("/v1/transfers/{id}/complete", post(complete))
        .layer(DefaultBodyLimit::max(CHUNK_SIZE)).with_state(state);
    emit(json!({"event":"ready", "ticket": identity.ticket(advertise, port)?, "address":format!("{advertise}:{port}"), "fingerprint":identity.fingerprint()?, "inbox":inbox}));
    let handle = axum_server::Handle::new();
    let shutdown = handle.clone();
    let shutdown_task = tokio::spawn(async move {
        while !*stopped.borrow() {
            if stopped.changed().await.is_err() { break; }
        }
        shutdown.graceful_shutdown(Some(std::time::Duration::from_secs(3)));
    });
    let result = axum_server::from_tcp_rustls(listener, config)?.handle(handle).serve(app.into_make_service()).await;
    shutdown_task.abort();
    result?;
    drop(lock);
    Ok(())
}
