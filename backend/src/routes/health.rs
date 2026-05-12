use axum::{
    Json, http::StatusCode,
    extract::{Path, Query, State},
};
use base64::Engine;
use chrono::NaiveDate;
use serde::{Deserialize, Serialize};

use crate::{error::{AppResult, AppError}, models::AppState, pagination::Pagination};

#[derive(Serialize, sqlx::FromRow)]
pub struct DailyHealth {
    pub date: String,
    pub avg_hr: Option<i64>,
    pub min_hr: Option<i64>,
    pub max_hr: Option<i64>,
    pub hrv_rmssd: Option<f64>,
    pub steps: Option<i64>,
}

#[derive(Serialize, sqlx::FromRow)]
pub struct BodyPicture {
    pub id: i64,
    pub picture_date: String,
    pub created_at: String,
}

#[derive(Serialize)]
pub struct PictureResponse {
    pub picture_data: String, // base64 encoded
    pub picture_date: String,
    pub created_at: String,
}

#[derive(Deserialize)]
pub struct UploadPictureRequest {
    pub picture_date: String, // YYYY-MM-DD format
    pub picture_data: String, // base64 encoded PNG
}

#[derive(Deserialize)]
pub struct PictureListQuery {
    pub from: Option<String>,
    pub to: Option<String>,
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

/// Upload a body picture for a given date. Auto-replaces if picture already exists.
///
/// # Errors
/// Returns an error if the database query fails or invalid date format.
pub async fn upload_picture(
    State(state): State<AppState>,
    Json(req): Json<UploadPictureRequest>,
) -> AppResult<(StatusCode, Json<serde_json::Value>)> {
    // Validate date format
    NaiveDate::parse_from_str(&req.picture_date, "%Y-%m-%d")
        .map_err(|_| AppError::from((StatusCode::BAD_REQUEST, "Invalid date format. Use YYYY-MM-DD".to_string())))?;

    // Decode base64 to get raw PNG bytes
    let picture_bytes = base64::engine::general_purpose::STANDARD
        .decode(&req.picture_data)
        .map_err(|_| AppError::from((StatusCode::BAD_REQUEST, "Invalid base64 encoding".to_string())))?;

    // Verify it's a valid image format (PNG or JPEG)
    let is_png = picture_bytes.len() >= 8 && &picture_bytes[..8] == b"\x89PNG\r\n\x1a\n";
    let is_jpeg = picture_bytes.len() >= 2 && &picture_bytes[..2] == b"\xff\xd8";
    if !is_png && !is_jpeg {
        return Err(AppError::from((StatusCode::BAD_REQUEST, "Invalid image format. Must be PNG or JPEG".to_string())));
    }

    // Insert or replace picture
    sqlx::query(
        "INSERT INTO body_pictures (picture_date, picture_data, created_at, updated_at)
         VALUES (?, ?, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
         ON CONFLICT(picture_date) DO UPDATE SET 
           picture_data = excluded.picture_data,
           updated_at = CURRENT_TIMESTAMP",
    )
    .bind(&req.picture_date)
    .bind(&picture_bytes)
    .execute(&state.pool)
    .await?;

    Ok((
        StatusCode::CREATED,
        Json(serde_json::json!({
            "success": true,
            "picture_date": req.picture_date
        })),
    ))
}

/// List pictures within a date range
///
/// # Errors
/// Returns an error if the database query fails or invalid date format.
pub async fn list_pictures(
    State(state): State<AppState>,
    Query(query): Query<PictureListQuery>,
) -> AppResult<Json<Vec<BodyPicture>>> {
    let from = query.from.unwrap_or_else(|| "2000-01-01".to_string());
    let to = query.to.unwrap_or_else(|| "2099-12-31".to_string());

    // Validate date formats
    NaiveDate::parse_from_str(&from, "%Y-%m-%d")
        .map_err(|_| AppError::from((StatusCode::BAD_REQUEST, "Invalid from date format".to_string())))?;
    NaiveDate::parse_from_str(&to, "%Y-%m-%d")
        .map_err(|_| AppError::from((StatusCode::BAD_REQUEST, "Invalid to date format".to_string())))?;

    let rows = sqlx::query_as::<_, BodyPicture>(
        "SELECT id, picture_date, created_at FROM body_pictures
         WHERE picture_date BETWEEN ? AND ?
         ORDER BY picture_date DESC",
    )
    .bind(&from)
    .bind(&to)
    .fetch_all(&state.pool)
    .await?;

    Ok(Json(rows))
}

/// Get a specific picture by date
///
/// # Errors
/// Returns 404 if picture not found or database error occurs.
pub async fn get_picture(
    State(state): State<AppState>,
    Path(picture_date): Path<String>,
) -> AppResult<Json<PictureResponse>> {
    // Validate date format
    NaiveDate::parse_from_str(&picture_date, "%Y-%m-%d")
        .map_err(|_| AppError::from((StatusCode::BAD_REQUEST, "Invalid date format. Use YYYY-MM-DD".to_string())))?;

    let row = sqlx::query_as::<_, (Vec<u8>, String, String)>(
        "SELECT picture_data, picture_date, created_at FROM body_pictures
         WHERE picture_date = ?",
    )
    .bind(&picture_date)
    .fetch_optional(&state.pool)
    .await?;

    let (image_bytes, stored_date, created_at) = row.ok_or_else(|| AppError::from((StatusCode::NOT_FOUND, "Picture not found".to_string())))?;

    // Encode picture bytes to base64
    let picture_data_encoded = base64::engine::general_purpose::STANDARD.encode(&image_bytes);

    Ok(Json(PictureResponse {
        picture_data: picture_data_encoded,
        picture_date: stored_date,
        created_at,
    }))
}

/// Delete a picture by date
///
/// # Errors
/// Returns 404 if picture not found or database error occurs.
pub async fn delete_picture(
    State(state): State<AppState>,
    Path(picture_date): Path<String>,
) -> AppResult<StatusCode> {
    // Validate date format
    NaiveDate::parse_from_str(&picture_date, "%Y-%m-%d")
        .map_err(|_| AppError::from((StatusCode::BAD_REQUEST, "Invalid date format. Use YYYY-MM-DD".to_string())))?;

    let result = sqlx::query(
        "DELETE FROM body_pictures WHERE picture_date = ?",
    )
    .bind(&picture_date)
    .execute(&state.pool)
    .await?;

    if result.rows_affected() == 0 {
        return Err(AppError::from((StatusCode::NOT_FOUND, "Picture not found".to_string())));
    }

    Ok(StatusCode::NO_CONTENT)
}
