//! Storage for BLE-fetched health data.
//!
//! Raw per-minute samples land in `activity_samples` (insert-or-replace, so
//! overlapping re-fetches are idempotent); `daily_health` aggregates are
//! recomputed from those samples with the exact same SQL conventions the
//! Gadgetbridge zip sync uses (`hr > 0 AND hr < 255`, steps summed over
//! valid-hr rows, UTC date grouping).

use chrono::Utc;
use sqlx::SqlitePool;

use crate::ble::parsers::{ActivitySample, HrMark, HrvSample};

/// Insert or replace raw activity samples; returns the affected UTC dates.
///
/// # Errors
/// Propagates sqlx errors.
pub async fn store_activity_samples(
    pool: &SqlitePool,
    samples: &[ActivitySample],
) -> Result<Vec<String>, sqlx::Error> {
    let mut dates: Vec<String> = Vec::new();
    for s in samples {
        sqlx::query(
            "INSERT OR REPLACE INTO activity_samples (ts, kind, steps, hr) VALUES (?, ?, ?, ?)",
        )
        .bind(s.ts)
        .bind(i64::from(s.kind))
        .bind(i64::from(s.steps))
        .bind(i64::from(s.hr))
        .execute(pool)
        .await?;
        let date = utc_date(s.ts);
        if !dates.contains(&date) {
            dates.push(date);
        }
    }
    Ok(dates)
}

/// Insert new HRV samples (ignoring ones already stored); returns affected dates.
///
/// # Errors
/// Propagates sqlx errors.
pub async fn store_hrv_samples(
    pool: &SqlitePool,
    samples: &[HrvSample],
) -> Result<Vec<String>, sqlx::Error> {
    let mut dates: Vec<String> = Vec::new();
    for s in samples {
        sqlx::query("INSERT OR IGNORE INTO hrv_samples (ts, value) VALUES (?, ?)")
            .bind(s.ts)
            .bind(i64::from(s.value))
            .execute(pool)
            .await?;
        let date = utc_date(s.ts);
        if !dates.contains(&date) {
            dates.push(date);
        }
    }
    Ok(dates)
}

/// Upsert resting (`max=false`) or max (`max=true`) HR marks for the UTC dates
/// of the given records, preserving the other column.
///
/// # Errors
/// Propagates sqlx errors.
pub async fn store_hr_marks(
    pool: &SqlitePool,
    marks: &[HrMark],
    max: bool,
) -> Result<(), sqlx::Error> {
    let now = Utc::now().to_rfc3339();
    for m in marks {
        sqlx::query(
            "INSERT INTO daily_hr_marks (date, resting_hr, max_hr, updated_at) \
             VALUES (date(?, 'unixepoch'), ?, ?, ?) \
             ON CONFLICT(date) DO UPDATE SET \
               resting_hr = COALESCE(excluded.resting_hr, daily_hr_marks.resting_hr), \
               max_hr = COALESCE(excluded.max_hr, daily_hr_marks.max_hr), \
               updated_at = excluded.updated_at",
        )
        .bind(m.epoch)
        .bind(Some(i64::from(m.hr)).filter(|_| !max))
        .bind(Some(i64::from(m.hr)).filter(|_| max))
        .bind(&now)
        .execute(pool)
        .await?;
    }
    Ok(())
}

/// Recompute `daily_health` HR/steps aggregates for the given UTC dates from
/// `activity_samples`, and `hrv_rmssd` from `hrv_samples`.
///
/// # Errors
/// Propagates sqlx errors.
pub async fn refresh_daily_health(pool: &SqlitePool, dates: &[String]) -> Result<(), sqlx::Error> {
    for date in dates {
        sqlx::query(
            "INSERT INTO daily_health (date, avg_hr, min_hr, max_hr, steps) \
             SELECT ?, CAST(AVG(hr) AS INTEGER), MIN(hr), MAX(hr), CAST(SUM(steps) AS INTEGER) \
             FROM activity_samples \
             WHERE hr > 0 AND hr < 255 AND DATE(ts, 'unixepoch') = ? \
             ON CONFLICT(date) DO UPDATE SET \
               avg_hr = excluded.avg_hr, min_hr = excluded.min_hr, \
               max_hr = excluded.max_hr, steps = excluded.steps",
        )
        .bind(date)
        .bind(date)
        .execute(pool)
        .await?;

        sqlx::query(
            "INSERT INTO daily_health (date, hrv_rmssd) \
             SELECT ?, AVG(value) FROM hrv_samples WHERE DATE(ts, 'unixepoch') = ? \
             ON CONFLICT(date) DO UPDATE SET hrv_rmssd = excluded.hrv_rmssd",
        )
        .bind(date)
        .bind(date)
        .execute(pool)
        .await?;
    }
    Ok(())
}

/// Record the sync pointer for one fetch type.
///
/// # Errors
/// Propagates sqlx errors.
pub async fn update_sync_state(
    pool: &SqlitePool,
    data_type: u8,
    last_sync_ts: i64,
    ack: u8,
) -> Result<(), sqlx::Error> {
    sqlx::query(
        "INSERT INTO watch_sync_state (data_type, last_sync_ts, last_ack, updated_at) \
         VALUES (?, ?, ?, ?) \
         ON CONFLICT(data_type) DO UPDATE SET \
           last_sync_ts = excluded.last_sync_ts, last_ack = excluded.last_ack, \
           updated_at = excluded.updated_at",
    )
    .bind(i64::from(data_type))
    .bind(last_sync_ts)
    .bind(i64::from(ack))
    .bind(Utc::now().to_rfc3339())
    .execute(pool)
    .await?;
    Ok(())
}

/// Load the last sync timestamp for a fetch type (0 when never synced).
///
/// # Errors
/// Propagates sqlx errors.
pub async fn load_sync_state(pool: &SqlitePool, data_type: u8) -> Result<i64, sqlx::Error> {
    let row: Option<(i64,)> =
        sqlx::query_as("SELECT last_sync_ts FROM watch_sync_state WHERE data_type = ?")
            .bind(i64::from(data_type))
            .fetch_optional(pool)
            .await?;
    Ok(row.map_or(0, |r| r.0))
}

/// UTC `YYYY-MM-DD` of a unix timestamp (the watch's local-as-UTC convention).
#[must_use]
pub fn utc_date(ts: i64) -> String {
    use chrono::TimeZone;
    Utc.timestamp_opt(ts, 0).single().map_or_else(
        || "1970-01-01".to_string(),
        |dt| dt.format("%Y-%m-%d").to_string(),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn utc_date_formats() {
        assert_eq!(utc_date(0), "1970-01-01");
        assert_eq!(utc_date(1_699_950_600), "2023-11-14");
    }
}

// ── Workouts (phase 4) ──────────────────────────────────────────────────────

/// A parsed workout summary ready for the `runs` table.
#[derive(Debug, Clone)]
pub struct BleWorkout {
    pub source_file: String,
    pub started_at: String,
    pub duration_s: i64,
    pub distance_m: f64,
    pub avg_hr: Option<i64>,
    pub max_hr: Option<i64>,
    pub avg_cadence: Option<i64>,
    pub avg_stride_m: Option<f64>,
    pub calories: Option<i64>,
}

/// Insert or update a BLE-imported run (dedupe key: `source_file`).
///
/// # Errors
/// Propagates sqlx errors.
pub async fn upsert_ble_run(pool: &SqlitePool, workout: &BleWorkout) -> Result<(), sqlx::Error> {
    sqlx::query(
        "INSERT INTO runs \
         (started_at, duration_s, distance_m, avg_hr, max_hr, avg_cadence, avg_stride_m, calories, source_file) \
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?) \
         ON CONFLICT(source_file) WHERE source_file IS NOT NULL DO UPDATE SET \
           started_at    = excluded.started_at, \
           duration_s    = excluded.duration_s, \
           distance_m    = excluded.distance_m, \
           avg_hr        = excluded.avg_hr, \
           max_hr        = excluded.max_hr, \
           avg_cadence   = excluded.avg_cadence, \
           avg_stride_m  = excluded.avg_stride_m, \
           calories      = excluded.calories",
    )
    .bind(&workout.started_at)
    .bind(workout.duration_s)
    .bind(workout.distance_m)
    .bind(workout.avg_hr)
    .bind(workout.max_hr)
    .bind(workout.avg_cadence)
    .bind(workout.avg_stride_m)
    .bind(workout.calories)
    .bind(&workout.source_file)
    .execute(pool)
    .await?;
    Ok(())
}

/// Attach the parsed GPS route (and weather) to a BLE-imported run. When the
/// summary distance was garbage (0), fill it from the route's haversine
/// distance instead.
///
/// # Errors
/// Propagates sqlx errors.
pub async fn update_run_route(
    pool: &SqlitePool,
    source_file: &str,
    route_json: &str,
    elevation_gain_m: Option<f64>,
    route_distance_m: f64,
    weather: Option<crate::weather::WeatherData>,
) -> Result<(), sqlx::Error> {
    sqlx::query(
        "UPDATE runs SET \
           route_json = ?, \
           elevation_gain_m = ?, \
           distance_m = CASE WHEN COALESCE(distance_m, 0) > 0 THEN distance_m ELSE ? END, \
           weather_temp_c = COALESCE(?, weather_temp_c), \
           weather_wind_kph = COALESCE(?, weather_wind_kph), \
           weather_precip_mm = COALESCE(?, weather_precip_mm), \
           weather_code = COALESCE(?, weather_code) \
         WHERE source_file = ?",
    )
    .bind(route_json)
    .bind(elevation_gain_m)
    .bind(route_distance_m)
    .bind(weather.as_ref().map(|w| w.temp_c))
    .bind(weather.as_ref().map(|w| w.wind_kph))
    .bind(weather.as_ref().map(|w| w.precip_mm))
    .bind(weather.as_ref().map(|w| w.code))
    .bind(source_file)
    .execute(pool)
    .await?;
    Ok(())
}

/// RFC3339 UTC formatting of a unix timestamp ("local-as-UTC" watch convention,
/// matching the GB zip sync's `started_at` format).
#[must_use]
pub fn rfc3339_utc(ts: i64) -> String {
    use chrono::TimeZone;
    Utc.timestamp_opt(ts, 0).single().map_or_else(
        || "1970-01-01T00:00:00Z".to_string(),
        |dt| dt.format("%Y-%m-%dT%H:%M:%SZ").to_string(),
    )
}
