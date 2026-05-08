use axum::{
    Json,
    extract::{Path, Query, State},
    http::StatusCode,
};
use serde::{Deserialize, Serialize};

use crate::{error::AppResult, models::AppState, pagination::Pagination};

#[derive(Serialize, sqlx::FromRow)]
pub struct WeightEntry {
    pub id: i64,
    pub measured_at: String,
    pub weight_kg: f64,
}

#[derive(Deserialize)]
pub struct CreateWeightEntry {
    pub weight_kg: f64,
    pub measured_at: Option<String>,
}

/// # Errors
/// Returns an error if the database query fails.
pub async fn list_weight(
    State(state): State<AppState>,
    Query(pagination): Query<Pagination>,
) -> AppResult<Json<Vec<WeightEntry>>> {
    let entries = sqlx::query_as::<_, WeightEntry>(
        "SELECT id, measured_at, weight_kg FROM weight_entries ORDER BY measured_at ASC LIMIT ? OFFSET ?",
    )
    .bind(pagination.limit)
    .bind(pagination.offset)
    .fetch_all(&state.pool)
    .await?;
    Ok(Json(entries))
}

/// # Errors
/// Returns an error if the database insert fails or weight is invalid.
pub async fn create_weight_entry(
    State(state): State<AppState>,
    Json(body): Json<CreateWeightEntry>,
) -> AppResult<(StatusCode, Json<WeightEntry>)> {
    if body.weight_kg <= 0.0 {
        return Err((
            StatusCode::BAD_REQUEST,
            "Weight must be positive".to_string(),
        )
            .into());
    }
    let entry = if let Some(ts) = body.measured_at {
        sqlx::query_as::<_, WeightEntry>(
            "INSERT INTO weight_entries (weight_kg, measured_at) VALUES (?, ?) \
             RETURNING id, measured_at, weight_kg",
        )
        .bind(body.weight_kg)
        .bind(ts)
        .fetch_one(&state.pool)
        .await?
    } else {
        sqlx::query_as::<_, WeightEntry>(
            "INSERT INTO weight_entries (weight_kg) VALUES (?) \
             RETURNING id, measured_at, weight_kg",
        )
        .bind(body.weight_kg)
        .fetch_one(&state.pool)
        .await?
    };
    Ok((StatusCode::CREATED, Json(entry)))
}

#[derive(Deserialize)]
pub struct UpdateWeightEntry {
    pub weight_kg: Option<f64>,
    pub measured_at: Option<String>,
}

/// # Errors
/// Returns `NOT_FOUND` if the entry doesn't exist, or `BAD_REQUEST` if weight is invalid.
pub async fn update_weight_entry(
    State(state): State<AppState>,
    Path(id): Path<i64>,
    Json(body): Json<UpdateWeightEntry>,
) -> AppResult<Json<WeightEntry>> {
    if let Some(w) = body.weight_kg
        && w <= 0.0
    {
        return Err((
            StatusCode::BAD_REQUEST,
            "Weight must be positive".to_string(),
        )
            .into());
    }
    let entry = sqlx::query_as::<_, WeightEntry>(
        "UPDATE weight_entries SET \
         weight_kg = COALESCE(?, weight_kg), \
         measured_at = COALESCE(?, measured_at) \
         WHERE id = ? RETURNING id, measured_at, weight_kg",
    )
    .bind(body.weight_kg)
    .bind(body.measured_at)
    .bind(id)
    .fetch_optional(&state.pool)
    .await?
    .ok_or(StatusCode::NOT_FOUND)?;
    Ok(Json(entry))
}

/// # Errors
/// Returns `NOT_FOUND` if the entry doesn't exist.
pub async fn delete_weight_entry(
    State(state): State<AppState>,
    Path(id): Path<i64>,
) -> AppResult<StatusCode> {
    let result = sqlx::query("DELETE FROM weight_entries WHERE id = ?")
        .bind(id)
        .execute(&state.pool)
        .await?;
    if result.rows_affected() == 0 {
        return Err(StatusCode::NOT_FOUND.into());
    }
    Ok(StatusCode::NO_CONTENT)
}
