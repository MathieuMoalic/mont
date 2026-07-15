use axum::{
    Json,
    extract::{Path, Query, State},
    http::StatusCode,
};
use chrono::NaiveDate;
use serde::Serialize;

use crate::{error::AppResult, models::AppState, pagination::Pagination};

#[derive(Serialize, sqlx::FromRow)]
pub struct HyroxDay {
    pub day: String,
}

fn validate_day(day: &str) -> bool {
    NaiveDate::parse_from_str(day, "%Y-%m-%d").is_ok()
}

/// # Errors
/// Returns an error if the database query fails.
pub async fn list_hyrox_days(
    State(state): State<AppState>,
    Query(pagination): Query<Pagination>,
) -> AppResult<Json<Vec<HyroxDay>>> {
    let rows = sqlx::query_as::<_, HyroxDay>(
        "SELECT day FROM hyrox_days ORDER BY day DESC LIMIT ? OFFSET ?",
    )
    .bind(pagination.limit)
    .bind(pagination.offset)
    .fetch_all(&state.pool)
    .await?;
    Ok(Json(rows))
}

/// # Errors
/// Returns `BAD_REQUEST` if day format is invalid or an error if the database insert fails.
pub async fn upsert_hyrox_day(
    State(state): State<AppState>,
    Path(day): Path<String>,
) -> AppResult<StatusCode> {
    if !validate_day(&day) {
        return Err((
            StatusCode::BAD_REQUEST,
            "day must be YYYY-MM-DD".to_string(),
        )
            .into());
    }

    sqlx::query("INSERT INTO hyrox_days(day) VALUES (?) ON CONFLICT(day) DO NOTHING")
        .bind(day)
        .execute(&state.pool)
        .await?;
    Ok(StatusCode::NO_CONTENT)
}

/// # Errors
/// Returns `BAD_REQUEST` if day format is invalid or an error if the database delete fails.
pub async fn delete_hyrox_day(
    State(state): State<AppState>,
    Path(day): Path<String>,
) -> AppResult<StatusCode> {
    if !validate_day(&day) {
        return Err((
            StatusCode::BAD_REQUEST,
            "day must be YYYY-MM-DD".to_string(),
        )
            .into());
    }

    sqlx::query("DELETE FROM hyrox_days WHERE day = ?")
        .bind(day)
        .execute(&state.pool)
        .await?;
    Ok(StatusCode::NO_CONTENT)
}
