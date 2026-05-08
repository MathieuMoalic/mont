use axum::{
    Json,
    extract::{Query, State},
};
use serde::Serialize;

use crate::{error::AppResult, models::AppState, pagination::Pagination};

#[derive(Serialize, sqlx::FromRow)]
pub struct DailyHealth {
    pub date: String,
    pub avg_hr: Option<i64>,
    pub min_hr: Option<i64>,
    pub max_hr: Option<i64>,
    pub hrv_rmssd: Option<f64>,
    pub steps: Option<i64>,
}

/// # Errors
/// Returns an error if the database query fails.
pub async fn list_daily_health(
    State(state): State<AppState>,
    Query(pagination): Query<Pagination>,
) -> AppResult<Json<Vec<DailyHealth>>> {
    let rows = sqlx::query_as::<_, DailyHealth>(
        "SELECT date, avg_hr, min_hr, max_hr, hrv_rmssd, steps \
         FROM daily_health ORDER BY date DESC LIMIT ? OFFSET ?",
    )
    .bind(pagination.limit)
    .bind(pagination.offset)
    .fetch_all(&state.pool)
    .await?;
    Ok(Json(rows))
}
