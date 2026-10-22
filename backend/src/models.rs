use crate::config::Config;
use crate::maps::Jobs;
use sqlx::SqlitePool;

#[derive(Clone)]
pub struct AppState {
    pub pool: SqlitePool,
    pub jwt_encoding: jsonwebtoken::EncodingKey,
    pub config: Config,
    pub http: reqwest::Client,
    pub maps_jobs: Jobs,
}
