use axum::{
    extract::{Multipart, State},
    http::StatusCode,
    Json,
};
use chrono::{DateTime, Utc};
use serde::Serialize;
use std::collections::HashMap;

use crate::{error::AppResult, models::AppState};

#[derive(Serialize, sqlx::FromRow)]
pub struct DailyHealth {
    pub date: String,
    pub avg_hr: Option<i64>,
    pub min_hr: Option<i64>,
    pub max_hr: Option<i64>,
    pub hrv_rmssd: Option<f64>,
    pub steps: Option<i64>,
}

// ── FIT health parsing ────────────────────────────────────────────────────────

#[derive(Default)]
struct DayAccum {
    hr_sum: i64,
    hr_count: i64,
    hr_min: i64,
    hr_max: i64,
    steps_max: i64,
    rr_intervals: Vec<f64>, // seconds
}

/// Parse a FIT monitoring file and return one [`DailyHealth`] per calendar day (UTC).
///
/// Expects `monitoring` records (global 55) with heart-rate in `unknown_field_20`
/// and step cycles in `cycles`, plus optional `hrv` records with RR-interval arrays.
///
/// # Errors
/// Returns an error if `data` is not a valid FIT file.
pub fn parse_health_fit(data: &[u8]) -> anyhow::Result<Vec<DailyHealth>> {
    let records = fitparser::from_bytes(data)
        .map_err(|e| anyhow::anyhow!("FIT parse error: {e}"))?;

    let mut days: HashMap<String, DayAccum> = HashMap::new();
    // Track the last UTC date seen from a monitoring timestamp so we can
    // associate HRV records (which carry no timestamp) with the right day.
    let mut last_date: Option<String> = None;

    for record in &records {
        match record.kind().to_string().as_str() {
            "monitoring" => accumulate_monitoring(record, &mut days, &mut last_date),
            "hrv" => accumulate_hrv(record, &mut days, last_date.as_ref()),
            _ => {}
        }
    }

    let mut result: Vec<DailyHealth> = days
        .into_iter()
        .map(|(date, acc)| finalize_day(date, &acc))
        .collect();
    result.sort_by(|a, b| a.date.cmp(&b.date));
    Ok(result)
}

fn accumulate_monitoring(
    record: &fitparser::FitDataRecord,
    days: &mut HashMap<String, DayAccum>,
    last_date: &mut Option<String>,
) {
    let mut ts_date: Option<String> = None;
    let mut hr: Option<i64> = None;
    let mut cycles: Option<f64> = None;

    for f in record.fields() {
        match f.name() {
            "timestamp" => {
                if let fitparser::Value::Timestamp(dt) = f.value() {
                    let utc: DateTime<Utc> = DateTime::from(*dt);
                    ts_date = Some(utc.format("%Y-%m-%d").to_string());
                }
            }
            "unknown_field_20" => {
                if let fitparser::Value::UInt8(v) = f.value() {
                    hr = Some(i64::from(*v));
                }
            }
            "cycles" => {
                if let fitparser::Value::Float64(v) = f.value() {
                    cycles = Some(*v);
                }
            }
            _ => {}
        }
    }

    let Some(ts_day) = ts_date else { return };
    *last_date = Some(ts_day.clone());
    let acc = days.entry(ts_day).or_default();

    if let Some(h) = hr
        && h > 0
    {
        acc.hr_sum += h;
        acc.hr_count += 1;
        if acc.hr_count == 1 {
            acc.hr_min = h;
            acc.hr_max = h;
        } else {
            acc.hr_min = acc.hr_min.min(h);
            acc.hr_max = acc.hr_max.max(h);
        }
    }
    if let Some(c) = cycles {
        // cycles field has scale=2 applied by fitparser; multiply back for steps
        #[allow(clippy::cast_possible_truncation)]
        let steps = (c * 2.0).round() as i64;
        acc.steps_max = acc.steps_max.max(steps);
    }
}

fn accumulate_hrv(
    record: &fitparser::FitDataRecord,
    days: &mut HashMap<String, DayAccum>,
    last_date: Option<&String>,
) {
    let Some(hrv_day) = last_date else { return };
    let acc = days.entry(hrv_day.clone()).or_default();

    for f in record.fields() {
        if f.name() == "time"
            && let fitparser::Value::Array(vals) = f.value()
        {
            for v in vals {
                if let fitparser::Value::Float64(rr_s) = v
                    && *rr_s > 0.0
                {
                    acc.rr_intervals.push(*rr_s);
                }
            }
        }
    }
}

fn finalize_day(date: String, acc: &DayAccum) -> DailyHealth {
    let avg_hr = (acc.hr_count > 0).then(|| acc.hr_sum / acc.hr_count);
    let min_hr = (acc.hr_count > 0).then_some(acc.hr_min);
    let max_hr = (acc.hr_count > 0).then_some(acc.hr_max);
    let steps = (acc.steps_max > 0).then_some(acc.steps_max);

    // RMSSD = sqrt(mean of squared successive differences) of RR intervals (ms)
    let hrv_rmssd = if acc.rr_intervals.len() >= 2 {
        let diffs_sq: Vec<f64> = acc
            .rr_intervals
            .windows(2)
            .map(|w| {
                let diff = (w[1] - w[0]) * 1000.0; // convert s → ms
                diff * diff
            })
            .collect();
        #[allow(clippy::cast_precision_loss)]
        Some((diffs_sq.iter().sum::<f64>() / diffs_sq.len() as f64).sqrt())
    } else {
        None
    };

    DailyHealth { date, avg_hr, min_hr, max_hr, hrv_rmssd, steps }
}

// ── Handlers ──────────────────────────────────────────────────────────────────

/// Import daily health data from a FIT monitoring file.
///
/// Accepts `multipart/form-data` with a single `file` field containing a FIT file.
/// Each day in the file is upserted into `daily_health`.
///
/// # Errors
/// Returns an error if multipart parsing, FIT parsing, or the database upsert fails.
pub async fn import_health_fit(
    State(state): State<AppState>,
    mut multipart: Multipart,
) -> AppResult<(StatusCode, Json<serde_json::Value>)> {
    let mut fit_data: Option<Vec<u8>> = None;
    while let Some(field) = multipart.next_field().await.map_err(|e| {
        (StatusCode::BAD_REQUEST, format!("multipart error: {e}"))
    })? {
        if field.name() == Some("file") {
            fit_data = Some(field.bytes().await.map_err(|e| {
                (StatusCode::BAD_REQUEST, format!("read error: {e}"))
            })?.to_vec());
            break;
        }
    }

    let data = fit_data.ok_or_else(|| {
        (StatusCode::BAD_REQUEST, "missing 'file' field".to_string())
    })?;

    let rows = parse_health_fit(&data)
        .map_err(|e| (StatusCode::UNPROCESSABLE_ENTITY, e.to_string()))?;

    let count = rows.len();
    for row in rows {
        sqlx::query(
            "INSERT INTO daily_health (date, avg_hr, min_hr, max_hr, hrv_rmssd, steps) \
             VALUES (?, ?, ?, ?, ?, ?) \
             ON CONFLICT(date) DO UPDATE SET \
               avg_hr   = excluded.avg_hr, \
               min_hr   = excluded.min_hr, \
               max_hr   = excluded.max_hr, \
               hrv_rmssd= excluded.hrv_rmssd, \
               steps    = excluded.steps",
        )
        .bind(&row.date)
        .bind(row.avg_hr)
        .bind(row.min_hr)
        .bind(row.max_hr)
        .bind(row.hrv_rmssd)
        .bind(row.steps)
        .execute(&state.pool)
        .await?;
    }

    Ok((StatusCode::CREATED, Json(serde_json::json!({ "imported": count }))))
}

// ─────────────────────────────────────────────────────────────────────────────

/// # Errors
/// Returns an error if the database query fails.
pub async fn list_daily_health(
    State(state): State<AppState>,
) -> AppResult<Json<Vec<DailyHealth>>> {
    let rows = sqlx::query_as::<_, DailyHealth>(
        "SELECT date, avg_hr, min_hr, max_hr, hrv_rmssd, steps \
         FROM daily_health ORDER BY date",
    )
    .fetch_all(&state.pool)
    .await?;
    Ok(Json(rows))
}
