use sqlx::SqlitePool;
use crate::config::Config;

#[allow(dead_code)] // pool will be used by feature route handlers
#[derive(Clone)]
pub struct AppState {
    pub pool: SqlitePool,
    pub jwt_encoding: jsonwebtoken::EncodingKey,
    pub config: Config,
}
