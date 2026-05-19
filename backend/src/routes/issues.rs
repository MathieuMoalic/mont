use axum::{
    Json,
    extract::{Query, State},
    http::StatusCode,
};
use serde::{Deserialize, Serialize};

use crate::{error::AppResult, models::AppState, pagination::Pagination};

#[derive(Serialize, sqlx::FromRow)]
pub struct IssueReport {
    pub id: i64,
    pub message: String,
    pub created_at: String,
    pub client_version: Option<String>,
    pub server_version: Option<String>,
    pub platform: Option<String>,
    pub base_url: Option<String>,
    pub route: Option<String>,
    pub extra_json: Option<String>,
}

#[derive(Deserialize)]
pub struct CreateIssueReport {
    pub message: String,
    pub client_version: Option<String>,
    pub server_version: Option<String>,
    pub platform: Option<String>,
    pub base_url: Option<String>,
    pub route: Option<String>,
    pub extra_json: Option<String>,
}

/// # Errors
/// Returns an error if the database insert fails.
pub async fn create_issue_report(
    State(state): State<AppState>,
    Json(body): Json<CreateIssueReport>,
) -> AppResult<(StatusCode, Json<IssueReport>)> {
    if body.message.trim().is_empty() {
        return Err((StatusCode::BAD_REQUEST, "Message is required".to_string()).into());
    }

    let report = sqlx::query_as::<_, IssueReport>(
        "INSERT INTO issue_reports (message, client_version, server_version, platform, base_url, route, extra_json) \
         VALUES (?, ?, ?, ?, ?, ?, ?) \
         RETURNING id, message, created_at, client_version, server_version, platform, base_url, route, extra_json",
    )
    .bind(body.message.trim())
    .bind(body.client_version)
    .bind(body.server_version)
    .bind(body.platform)
    .bind(body.base_url)
    .bind(body.route)
    .bind(body.extra_json)
    .fetch_one(&state.pool)
    .await?;

    Ok((StatusCode::CREATED, Json(report)))
}

/// # Errors
/// Returns an error if the database query fails.
pub async fn list_issue_reports(
    State(state): State<AppState>,
    Query(pagination): Query<Pagination>,
) -> AppResult<Json<Vec<IssueReport>>> {
    let reports = sqlx::query_as::<_, IssueReport>(
        "SELECT id, message, created_at, client_version, server_version, platform, base_url, route, extra_json \
         FROM issue_reports ORDER BY created_at DESC LIMIT ? OFFSET ?",
    )
    .bind(pagination.limit)
    .bind(pagination.offset)
    .fetch_all(&state.pool)
    .await?;

    Ok(Json(reports))
}

