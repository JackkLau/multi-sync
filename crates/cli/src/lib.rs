pub mod identity;
pub mod send;
pub mod server;

/// Each native client owns its event stream; credentials are never written to logs.
pub type EventSink = std::sync::Arc<dyn Fn(serde_json::Value) + Send + Sync>;

pub fn initialize_crypto() {
    let _ = rustls::crypto::ring::default_provider().install_default();
}
