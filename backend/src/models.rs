use crate::config::Config;
use crate::maps::Jobs;
use sqlx::SqlitePool;
use std::sync::Arc;
use tokio::sync::Mutex;

#[derive(Clone)]
pub struct AppState {
    pub pool: SqlitePool,
    pub jwt_encoding: jsonwebtoken::EncodingKey,
    pub config: Config,
    pub http: reqwest::Client,
    pub maps_jobs: Jobs,
    /// Held for the whole lifetime of a BLE relay session — the watch serves
    /// one GATT conversation at a time, so a second concurrent session breaks
    /// both (auth handshake collisions, dropped links). `try_lock` in the
    /// session entry point rejects the second connection with a busy result.
    pub ble_session_lock: Arc<Mutex<()>>,
}
