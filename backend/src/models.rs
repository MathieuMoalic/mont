use sqlx::SqlitePool;
use crate::config::Config;

#[derive(Clone)]
pub struct AppState {
    pub pool: SqlitePool,
    pub jwt_encoding: jsonwebtoken::EncodingKey,
    pub config: Config,
    pub http: reqwest::Client,
}
