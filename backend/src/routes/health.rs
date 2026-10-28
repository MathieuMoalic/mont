use axum::{
    Json,
    extract::{Path, Query, State},
    http::StatusCode,
};
use base64::Engine;
use chrono::{NaiveDate, TimeZone};
use serde::{Deserialize, Serialize};

use crate::{
    error::{AppError, AppResult},
    models::AppState,
    pagination::Pagination,
};

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
    NaiveDate::parse_from_str(&req.picture_date, "%Y-%m-%d").map_err(|_| {
        AppError::from((
            StatusCode::BAD_REQUEST,
            "Invalid date format. Use YYYY-MM-DD".to_string(),
        ))
    })?;

    // Decode base64 to get raw PNG bytes
    let picture_bytes = base64::engine::general_purpose::STANDARD
        .decode(&req.picture_data)
        .map_err(|_| {
            AppError::from((
                StatusCode::BAD_REQUEST,
                "Invalid base64 encoding".to_string(),
            ))
        })?;

    // Verify it's a valid image format (PNG or JPEG)
    let is_png = picture_bytes.len() >= 8 && &picture_bytes[..8] == b"\x89PNG\r\n\x1a\n";
    let is_jpeg = picture_bytes.len() >= 2 && &picture_bytes[..2] == b"\xff\xd8";
    if !is_png && !is_jpeg {
        return Err(AppError::from((
            StatusCode::BAD_REQUEST,
            "Invalid image format. Must be PNG or JPEG".to_string(),
        )));
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
    NaiveDate::parse_from_str(&from, "%Y-%m-%d").map_err(|_| {
        AppError::from((
            StatusCode::BAD_REQUEST,
            "Invalid from date format".to_string(),
        ))
    })?;
    NaiveDate::parse_from_str(&to, "%Y-%m-%d").map_err(|_| {
        AppError::from((
            StatusCode::BAD_REQUEST,
            "Invalid to date format".to_string(),
        ))
    })?;

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
    NaiveDate::parse_from_str(&picture_date, "%Y-%m-%d").map_err(|_| {
        AppError::from((
            StatusCode::BAD_REQUEST,
            "Invalid date format. Use YYYY-MM-DD".to_string(),
        ))
    })?;

    let row = sqlx::query_as::<_, (Vec<u8>, String, String)>(
        "SELECT picture_data, picture_date, created_at FROM body_pictures
         WHERE picture_date = ?",
    )
    .bind(&picture_date)
    .fetch_optional(&state.pool)
    .await?;

    let (image_bytes, stored_date, created_at) = row
        .ok_or_else(|| AppError::from((StatusCode::NOT_FOUND, "Picture not found".to_string())))?;

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
    NaiveDate::parse_from_str(&picture_date, "%Y-%m-%d").map_err(|_| {
        AppError::from((
            StatusCode::BAD_REQUEST,
            "Invalid date format. Use YYYY-MM-DD".to_string(),
        ))
    })?;

    let result = sqlx::query("DELETE FROM body_pictures WHERE picture_date = ?")
        .bind(&picture_date)
        .execute(&state.pool)
        .await?;

    if result.rows_affected() == 0 {
        return Err(AppError::from((
            StatusCode::NOT_FOUND,
            "Picture not found".to_string(),
        )));
    }

    Ok(StatusCode::NO_CONTENT)
}

// ── Morning glance (BLE watch data) ──────────────────────────────────────────

#[derive(Serialize)]
pub struct SleepNight {
    window_start: Option<i64>,
    window_end: Option<i64>,
    total_min: i64,
    deep_min: i64,
    rem_min: i64,
    light_min: i64,
    awake_min: i64,
    /// Minute-level stages as `[seconds since window start, code]` where
    /// code: 3 = deep, 2 = REM, 1 = light, 0 = awake.
    timeline: Vec<(i64, i8)>,
}

#[derive(Serialize)]
pub struct HrvNight {
    /// `[seconds since midnight of `date`, value]`
    points: Vec<(i64, i64)>,
    night_avg: Option<f64>,
    seven_day_avg: Option<f64>,
    baseline_min: Option<f64>,
    baseline_max: Option<f64>,
}

#[derive(Serialize)]
pub struct HrDay {
    /// `[seconds since midnight of `date`, hr]`
    points: Vec<(i64, i64)>,
    min: Option<i64>,
    avg: Option<f64>,
    max: Option<i64>,
    resting: Option<i64>,
}

#[derive(Serialize)]
pub struct MorningGlance {
    date: String,
    sleep: SleepNight,
    hrv: HrvNight,
    hr: HrDay,
    steps: Option<i64>,
    stress_avg: Option<f64>,
    stress_max: Option<i64>,
}

/// One `sleep_sessions` row for the morning glance.
#[derive(Debug, Clone, Copy, Default, sqlx::FromRow)]
struct NightSession {
    ts: i64,
    midnight_ts: i64,
    sleep_start_min: i64,
    sleep_end_min: i64,
    deep_min: i64,
    light_min: i64,
    rem_min: i64,
    wake_min: i64,
}

/// `GET /health/morning?date=YYYY-MM-DD` — the daily morning-glance data:
/// last night's sleep stages, nightly HRV with 7-day average and baseline,
/// the day's minute-level heart rate, steps and stress.
///
/// # Errors
/// Returns a 400 error for an invalid date, and propagates database errors.
#[allow(clippy::too_many_lines, clippy::cast_precision_loss)]
pub async fn morning(
    State(state): State<AppState>,
    Query(params): Query<MorningQuery>,
) -> AppResult<Json<MorningGlance>> {
    let date = params
        .date
        .clone()
        .unwrap_or_else(|| chrono::Local::now().format("%Y-%m-%d").to_string());
    chrono::NaiveDate::parse_from_str(&date, "%Y-%m-%d")
        .map_err(|_| AppError::from((StatusCode::BAD_REQUEST, "invalid date".into())))?;
    let pool = &state.pool;
    let day_start = chrono::NaiveDate::parse_from_str(&date, "%Y-%m-%d")
        .ok()
        .and_then(|d| d.and_hms_opt(0, 0, 0))
        .map_or(0, |d| d.and_utc().timestamp());
    // True local midnight for the sleep-session window: `sleep_sessions
    // .midnight_ts` is a real epoch (the parser applies the watch's tz
    // byte), unlike the local-as-UTC sample tables the rest of this
    // handler queries — `and_utc()` here leaked the next day's session
    // into the window by the UTC offset.
    let local_day_start = chrono::NaiveDate::parse_from_str(&date, "%Y-%m-%d")
        .ok()
        .and_then(|d| d.and_hms_opt(0, 0, 0))
        .and_then(|d| chrono::Local.from_local_datetime(&d).single())
        .map_or(0, |d| d.timestamp());

    // ── sleep: the watch's own session for this wake-up date (naps share the
    // same midnight; keep the session with the most asleep minutes). The
    // watch finalizes the latest night lazily, so a session-less date falls
    // back to the most recent night of the previous two days — "today" then
    // still shows last known night instead of an empty card.
    let sessions: Vec<NightSession> = sqlx::query_as(
        "SELECT ts, midnight_ts, sleep_start_min, sleep_end_min, \
                deep_min, light_min, rem_min, wake_min \
         FROM sleep_sessions \
         WHERE midnight_ts >= ? - 172800 AND midnight_ts < ? + 86400 \
         ORDER BY midnight_ts DESC, ts DESC",
    )
    .bind(local_day_start)
    .bind(local_day_start)
    .fetch_all(pool)
    .await
    .unwrap_or_default();
    let latest_midnight = sessions.first().map(|s| s.midnight_ts);
    let night = sessions
        .iter()
        .filter(|s| Some(s.midnight_ts) == latest_midnight)
        .max_by_key(|s| s.deep_min + s.light_min + s.rem_min)
        .copied()
        .unwrap_or_else(NightSession::default);

    let (window_start, window_end) = if night.ts == 0 {
        (None, None)
    } else {
        (
            Some(night.midnight_ts - 86_400 + night.sleep_start_min * 60),
            Some(night.midnight_ts - 86_400 + night.sleep_end_min * 60),
        )
    };
    let asleep = night.deep_min + night.light_min + night.rem_min;

    // Per-minute stage strip over the window: gaps (awake in bed, bathroom
    // breaks) are stage 0, stages overlay their normalized code.
    let timeline: Vec<(i64, i8)> = if night.ts == 0 {
        Vec::new()
    } else {
        let span = (night.sleep_end_min - night.sleep_start_min).max(0);
        let mut codes = vec![0i8; usize::try_from(span).unwrap_or(0)];
        let stages: Vec<(i64, i64, i64)> = sqlx::query_as(
            "SELECT start_min, end_min, stage FROM sleep_stages \
             WHERE session_ts = ? ORDER BY start_min",
        )
        .bind(night.ts)
        .fetch_all(pool)
        .await
        .unwrap_or_default();
        for (start, end, stage) in stages {
            let from = (start - night.sleep_start_min).clamp(0, span);
            let to = (end - night.sleep_start_min).clamp(0, span);
            for m in from..to {
                if let Some(slot) = codes.get_mut(usize::try_from(m).unwrap_or(usize::MAX)) {
                    *slot = i8::try_from(stage).unwrap_or(1);
                }
            }
        }
        codes
            .into_iter()
            .enumerate()
            .map(|(i, c)| (i64::try_from(i).unwrap_or(0), c))
            .collect()
    };

    let sleep = SleepNight {
        window_start,
        window_end,
        total_min: asleep,
        deep_min: night.deep_min,
        rem_min: night.rem_min,
        light_min: night.light_min,
        awake_min: night.wake_min,
        timeline,
    };

    // ── HRV: night values attributed to the wake-up date
    let hrv_points: Vec<(i64, i64)> = sqlx::query_as(
        "SELECT ts, value FROM hrv_samples WHERE date(ts + 43200, 'unixepoch') = ? ORDER BY ts",
    )
    .bind(&date)
    .fetch_all(pool)
    .await
    .unwrap_or_default();
    let night_avg = if hrv_points.is_empty() {
        None
    } else {
        Some(
            hrv_points.iter().map(|(_, v)| *v as f64).sum::<f64>()
                / f64::from(u32::try_from(hrv_points.len()).unwrap_or(1)),
        )
    };

    // 7-day average of nightly averages, and ~30-day baseline range
    let nightly: Vec<(String, f64)> = sqlx::query_as(
        "SELECT date(ts + 43200, 'unixepoch') AS d, AVG(value) FROM hrv_samples \
         WHERE ts >= strftime('%s', ? , '-32 days') GROUP BY d ORDER BY d",
    )
    .bind(&date)
    .fetch_all(pool)
    .await
    .unwrap_or_default();
    let past: Vec<f64> = nightly
        .iter()
        .filter(|(d, _)| d.as_str() < date.as_str())
        .map(|(_, v)| *v)
        .collect();
    let seven_day_avg = if past.len() >= 7 {
        let last7: Vec<f64> = past.iter().rev().take(7).copied().collect();
        Some(last7.iter().sum::<f64>() / f64::from(u32::try_from(last7.len()).unwrap_or(1)))
    } else {
        None
    };
    let (baseline_min, baseline_max) = if past.is_empty() {
        (None, None)
    } else {
        (
            Some(past.iter().copied().fold(f64::MAX, f64::min)),
            Some(past.iter().copied().fold(f64::MIN, f64::max)),
        )
    };

    let hrv = HrvNight {
        points: hrv_points
            .iter()
            .map(|(ts, v)| {
                (
                    ts.saturating_sub(
                        chrono::NaiveDate::parse_from_str(&date, "%Y-%m-%d")
                            .ok()
                            .and_then(|d| d.and_hms_opt(0, 0, 0))
                            .map_or(0, |d| d.and_utc().timestamp()),
                    ),
                    *v,
                )
            })
            .collect(),
        night_avg,
        seven_day_avg,
        baseline_min,
        baseline_max,
    };

    // ── HR: minute-level values for the date
    let hr_rows: Vec<(i64, i64)> = sqlx::query_as(
        "SELECT ts - ?, hr FROM activity_samples \
         WHERE date(ts, 'unixepoch') = ? AND hr > 0 AND hr < 255 ORDER BY ts",
    )
    .bind(day_start)
    .bind(&date)
    .fetch_all(pool)
    .await
    .unwrap_or_default();
    let hr_min = hr_rows.iter().map(|(_, h)| *h).min();
    let hr_max = hr_rows.iter().map(|(_, h)| *h).max();
    let hr_avg = if hr_rows.is_empty() {
        None
    } else {
        Some(
            hr_rows.iter().map(|(_, h)| *h as f64).sum::<f64>()
                / f64::from(u32::try_from(hr_rows.len()).unwrap_or(1)),
        )
    };
    let resting: Option<i64> =
        sqlx::query_scalar("SELECT resting_hr FROM daily_hr_marks WHERE date = ?")
            .bind(&date)
            .fetch_one(pool)
            .await
            .unwrap_or(None);
    let hr = HrDay {
        points: hr_rows,
        min: hr_min,
        avg: hr_avg,
        max: hr_max,
        resting,
    };

    // ── steps + stress for the date
    let steps: Option<i64> = sqlx::query_scalar(
        "SELECT SUM(steps) FROM activity_samples WHERE date(ts, 'unixepoch') = ?",
    )
    .bind(&date)
    .fetch_one(pool)
    .await
    .unwrap_or(None);
    let (stress_avg, stress_max): (Option<f64>, Option<i64>) = sqlx::query_as(
        "SELECT AVG(stress), MAX(stress) FROM stress_samples WHERE date(ts, 'unixepoch') = ?",
    )
    .bind(&date)
    .fetch_one(pool)
    .await
    .unwrap_or((None, None));

    Ok(Json(MorningGlance {
        date,
        sleep,
        hrv,
        hr,
        steps,
        stress_avg,
        stress_max,
    }))
}

#[derive(Deserialize)]
pub struct MorningQuery {
    date: Option<String>,
}
