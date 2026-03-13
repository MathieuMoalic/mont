use axum::{
    extract::{Multipart, Path, State},
    http::StatusCode,
    Json,
};
use serde::{Deserialize, Serialize};

use crate::{error::AppResult, models::AppState};

// ── DB / response types ───────────────────────────────────────────────────────

#[derive(Serialize, sqlx::FromRow)]
pub struct RunSummary {
    pub id: i64,
    pub started_at: String,
    pub duration_s: i64,
    pub distance_m: f64,
    pub elevation_gain_m: Option<f64>,
    pub avg_hr: Option<i64>,
    pub max_hr: Option<i64>,
    pub notes: Option<String>,
    pub is_invalid: bool,
    pub avg_cadence: Option<i64>,
    pub avg_stride_m: Option<f64>,
}

#[derive(Serialize)]
pub struct RunDetail {
    pub id: i64,
    pub started_at: String,
    pub duration_s: i64,
    pub distance_m: f64,
    pub elevation_gain_m: Option<f64>,
    pub avg_hr: Option<i64>,
    pub max_hr: Option<i64>,
    pub notes: Option<String>,
    pub route: Vec<RoutePoint>,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct RoutePoint {
    pub lat: f64,
    pub lon: f64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub ele: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub hr: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub t: Option<i64>, // seconds since run start
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cad: Option<i64>, // steps per minute
}

// ── GPX parsing ───────────────────────────────────────────────────────────────

struct TrackPoint {
    lat: f64,
    lon: f64,
    ele: Option<f64>,
    time_secs: Option<i64>,
    hr: Option<i64>,
    cad: Option<i64>,
    speed: Option<f64>,
}

struct ParsedRun {
    started_at: String,
    duration_s: i64,
    distance_m: f64,
    elevation_gain_m: Option<f64>,
    avg_hr: Option<i64>,
    max_hr: Option<i64>,
    avg_cadence: Option<i64>,
    avg_stride_m: Option<f64>,
    route: Vec<RoutePoint>,
    activity_type: Option<String>,
}

fn is_running_activity(activity_type: Option<&str>) -> bool {
    // No type field → assume running (e.g. manually-created GPX files)
    activity_type.is_none_or(|t| matches!(t, "running" | "trail_running" | "run"))
}

fn parse_timestamp(s: &str) -> anyhow::Result<i64> {
    use chrono::DateTime;
    Ok(DateTime::parse_from_rfc3339(s)?.timestamp())
}

fn haversine_m(lat1: f64, lon1: f64, lat2: f64, lon2: f64) -> f64 {
    const R: f64 = 6_371_000.0;
    let dlat = (lat2 - lat1).to_radians();
    let dlon = (lon2 - lon1).to_radians();
    let a = f64::mul_add(
        lat1.to_radians().cos() * lat2.to_radians().cos(),
        (dlon / 2.0).sin().powi(2),
        (dlat / 2.0).sin().powi(2),
    );
    R * 2.0 * a.sqrt().asin()
}

struct RunStats {
    avg_hr: Option<i64>,
    max_hr: Option<i64>,
    avg_cadence: Option<i64>,
    avg_stride_m: Option<f64>,
}

fn compute_run_stats(points: &[TrackPoint]) -> RunStats {
    let hr_values: Vec<i64> = points.iter().filter_map(|p| p.hr).collect();
    let avg_hr = if hr_values.is_empty() {
        None
    } else {
        #[allow(clippy::cast_possible_truncation)]
        Some(hr_values.iter().sum::<i64>() / i64::try_from(hr_values.len()).unwrap_or(1))
    };
    let max_hr = hr_values.into_iter().max();

    let cad_values: Vec<i64> = points.iter().filter_map(|p| p.cad).collect();
    let avg_cadence = if cad_values.is_empty() {
        None
    } else {
        #[allow(clippy::cast_possible_truncation)]
        Some(cad_values.iter().sum::<i64>() / i64::try_from(cad_values.len()).unwrap_or(1))
    };

    // Stride length (m) = speed_m_s * 120 / cadence_spm  (cadence = total steps/min)
    let avg_stride_m = avg_cadence.and_then(|cad| {
        let speed_values: Vec<f64> = points.iter().filter_map(|p| p.speed).collect();
        if speed_values.is_empty() || cad == 0 {
            None
        } else {
            let avg_speed = speed_values.iter().sum::<f64>()
                / f64::from(u32::try_from(speed_values.len()).unwrap_or(1));
            #[allow(clippy::cast_precision_loss)]
            Some(avg_speed * 120.0 / cad as f64)
        }
    });

    RunStats { avg_hr, max_hr, avg_cadence, avg_stride_m }
}

fn parse_trkpt(node: roxmltree::Node<'_, '_>) -> anyhow::Result<TrackPoint> {
    let lat: f64 = node
        .attribute("lat")
        .ok_or_else(|| anyhow::anyhow!("trkpt missing lat"))?
        .parse()?;
    let lon: f64 = node
        .attribute("lon")
        .ok_or_else(|| anyhow::anyhow!("trkpt missing lon"))?
        .parse()?;
    let child_text = |name: &str| node.children().find(|n| n.tag_name().name() == name).and_then(|n| n.text());
    let ext_text = |name: &str| node.descendants().find(|n| n.tag_name().name() == name).and_then(|n| n.text());
    let ele = child_text("ele").and_then(|t| t.parse::<f64>().ok());
    let time_secs = child_text("time").and_then(|t| parse_timestamp(t).ok());
    let hr = ext_text("hr").and_then(|t| t.parse::<i64>().ok());
    let cad = ext_text("cad").and_then(|t| t.parse::<i64>().ok()).filter(|&c| c > 0);
    let speed = ext_text("speed").and_then(|t| t.parse::<f64>().ok()).filter(|&s| s > 0.0);
    Ok(TrackPoint { lat, lon, ele, time_secs, hr, cad, speed })
}

fn compute_timing(points: &[TrackPoint]) -> (String, i64) {
    let started_at = points
        .first()
        .and_then(|p| p.time_secs)
        .map(|ts| {
            use chrono::{DateTime, Utc};
            DateTime::<Utc>::from_timestamp(ts, 0)
                .map(|dt| dt.format("%Y-%m-%dT%H:%M:%SZ").to_string())
                .unwrap_or_default()
        })
        .unwrap_or_default();
    let duration_s = match (points.first().and_then(|p| p.time_secs), points.last().and_then(|p| p.time_secs)) {
        (Some(s), Some(e)) => (e - s).max(0),
        _ => 0,
    };
    (started_at, duration_s)
}

fn compute_elevation_gain(points: &[TrackPoint]) -> Option<f64> {
    let elevations: Vec<f64> = points.iter().filter_map(|p| p.ele).collect();
    if elevations.len() < 2 { return None; }
    let gain: f64 = elevations.windows(2)
        .filter_map(|w| { let d = w[1] - w[0]; if d > 0.0 { Some(d) } else { None } })
        .sum();
    Some(gain)
}

fn parse_gpx(data: &[u8]) -> anyhow::Result<ParsedRun> {
    let text = std::str::from_utf8(data)?;
    let doc = roxmltree::Document::parse(text)?;

    let activity_type = doc
        .descendants()
        .find(|n| n.tag_name().name() == "trk")
        .and_then(|trk| trk.children().find(|n| n.tag_name().name() == "type"))
        .and_then(|n| n.text())
        .map(|t| t.trim().to_lowercase());

    let points = doc.descendants()
        .filter(|n| n.tag_name().name() == "trkpt")
        .map(parse_trkpt)
        .collect::<anyhow::Result<Vec<_>>>()?;

    anyhow::ensure!(!points.is_empty(), "GPX contains no track points");

    let (started_at, duration_s) = compute_timing(&points);
    let distance_m: f64 = points.windows(2)
        .map(|w| haversine_m(w[0].lat, w[0].lon, w[1].lat, w[1].lon))
        .sum();
    let elevation_gain_m = compute_elevation_gain(&points);
    let stats = compute_run_stats(&points);

    let route = {
        let t0 = points.first().and_then(|p| p.time_secs);
        points.into_iter().map(|p| RoutePoint {
            lat: p.lat, lon: p.lon, ele: p.ele, hr: p.hr,
            t: p.time_secs.and_then(|ts| t0.map(|t0| ts - t0)),
            cad: p.cad.filter(|&c| c > 0),
        }).collect()
    };

    Ok(ParsedRun {
        started_at, duration_s, distance_m, elevation_gain_m,
        avg_hr: stats.avg_hr, max_hr: stats.max_hr,
        avg_cadence: stats.avg_cadence, avg_stride_m: stats.avg_stride_m,
        route, activity_type,
    })
}

// ── Handlers ──────────────────────────────────────────────────────────────────

/// # Errors
/// Returns `BAD_REQUEST` if the multipart body is malformed or missing the `file` field,
/// `UNPROCESSABLE_ENTITY` if the GPX cannot be parsed, or a database error.
pub async fn import_run(
    State(state): State<AppState>,
    mut multipart: Multipart,
) -> AppResult<(StatusCode, Json<RunSummary>)> {
    let mut gpx_bytes: Option<Vec<u8>> = None;

    while let Some(field) = multipart
        .next_field()
        .await
        .map_err(|e| (StatusCode::BAD_REQUEST, e.body_text()))?
    {
        if field.name() == Some("file") {
            gpx_bytes = Some(
                field
                    .bytes()
                    .await
                    .map_err(|e| (StatusCode::BAD_REQUEST, e.body_text()))?
                    .to_vec(),
            );
        }
    }

    let bytes = gpx_bytes
        .ok_or_else(|| (StatusCode::BAD_REQUEST, "Missing `file` field".to_string()))?;

    let parsed = parse_gpx(&bytes)
        .map_err(|e| (StatusCode::UNPROCESSABLE_ENTITY, e.to_string()))?;

    if !is_running_activity(parsed.activity_type.as_deref()) {
        return Err((
            StatusCode::UNPROCESSABLE_ENTITY,
            format!(
                "Activity type '{}' is not a running activity",
                parsed.activity_type.as_deref().unwrap_or("unknown")
            ),
        ).into());
    }

    let route_json = serde_json::to_string(&parsed.route)
        .map_err(anyhow::Error::from)?;

    let run = sqlx::query_as::<_, RunSummary>(
        "INSERT INTO runs \
         (started_at, duration_s, distance_m, elevation_gain_m, avg_hr, max_hr, route_json, avg_cadence, avg_stride_m) \
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?) \
         RETURNING id, started_at, duration_s, distance_m, elevation_gain_m, avg_hr, max_hr, notes, is_invalid, avg_cadence, avg_stride_m",
    )
    .bind(&parsed.started_at)
    .bind(parsed.duration_s)
    .bind(parsed.distance_m)
    .bind(parsed.elevation_gain_m)
    .bind(parsed.avg_hr)
    .bind(parsed.max_hr)
    .bind(&route_json)
    .bind(parsed.avg_cadence)
    .bind(parsed.avg_stride_m)
    .fetch_one(&state.pool)
    .await?;

    Ok((StatusCode::CREATED, Json(run)))
}

/// # Errors
/// Returns an error if the database query fails.
pub async fn list_runs(State(state): State<AppState>) -> AppResult<Json<Vec<RunSummary>>> {
    let runs = sqlx::query_as::<_, RunSummary>(
        "SELECT id, started_at, duration_s, distance_m, elevation_gain_m, avg_hr, max_hr, notes, is_invalid, avg_cadence, avg_stride_m \
         FROM runs ORDER BY started_at DESC",
    )
    .fetch_all(&state.pool)
    .await?;
    Ok(Json(runs))
}

/// # Errors
/// Returns `NOT_FOUND` if the run doesn't exist, or a database error.
pub async fn get_run(
    State(state): State<AppState>,
    Path(id): Path<i64>,
) -> AppResult<Json<RunDetail>> {
    #[derive(sqlx::FromRow)]
    struct RunRow {
        id: i64,
        started_at: String,
        duration_s: i64,
        distance_m: f64,
        elevation_gain_m: Option<f64>,
        avg_hr: Option<i64>,
        max_hr: Option<i64>,
        notes: Option<String>,
        route_json: String,
    }

    let row = sqlx::query_as::<_, RunRow>(
        "SELECT id, started_at, duration_s, distance_m, elevation_gain_m, \
                avg_hr, max_hr, notes, route_json \
         FROM runs WHERE id = ?",
    )
    .bind(id)
    .fetch_optional(&state.pool)
    .await?
    .ok_or(StatusCode::NOT_FOUND)?;

    let route: Vec<RoutePoint> = serde_json::from_str(&row.route_json).unwrap_or_default();

    Ok(Json(RunDetail {
        id: row.id,
        started_at: row.started_at,
        duration_s: row.duration_s,
        distance_m: row.distance_m,
        elevation_gain_m: row.elevation_gain_m,
        avg_hr: row.avg_hr,
        max_hr: row.max_hr,
        notes: row.notes,
        route,
    }))
}

/// # Errors
/// Returns `NOT_FOUND` if the run doesn't exist.
pub async fn delete_run(
    State(state): State<AppState>,
    Path(id): Path<i64>,
) -> AppResult<StatusCode> {
    let result = sqlx::query("DELETE FROM runs WHERE id = ?")
        .bind(id)
        .execute(&state.pool)
        .await?;
    if result.rows_affected() == 0 {
        return Err(StatusCode::NOT_FOUND.into());
    }
    Ok(StatusCode::NO_CONTENT)
}

/// Delete **all** runs so they can be reimported from scratch.
///
/// # Errors
/// Returns a database error if the deletion fails.
pub async fn delete_all_runs(
    State(state): State<AppState>,
) -> AppResult<StatusCode> {
    sqlx::query("DELETE FROM runs")
        .execute(&state.pool)
        .await?;
    Ok(StatusCode::NO_CONTENT)
}

#[derive(Serialize)]
pub struct SyncResult {
    pub imported: usize,
    pub health_days: usize,
    pub errors: Vec<String>,
}

/// Aggregate struct returned by the blocking GB extraction task.
struct GbHealthRow {
    date: String,
    avg_hr: Option<i64>,
    min_hr: Option<i64>,
    max_hr: Option<i64>,
    hrv_rmssd: Option<f64>,
    steps: Option<i64>,
}

/// Extract daily HR and HRV data from the Gadgetbridge `SQLite` DB.
/// Tries common activity-sample table names (Amazfit / Mi Band / Huami).
/// Silently skips tables that don't exist.
#[allow(clippy::similar_names)]
fn extract_daily_health(db_path: &std::path::Path) -> Vec<GbHealthRow> {
    let Ok(conn) = rusqlite::Connection::open(db_path) else { return vec![] };

    // ── HR: Amazfit Cheetah Pro uses HUAMI_EXTENDED_ACTIVITY_SAMPLE (seconds) ─
    // Fall back to MI_BAND / plain HUAMI if empty.
    let mut hr_accum: std::collections::HashMap<String, (i64, i64, i64, i64, i64)> =
        std::collections::HashMap::default(); // date → (sum_hr, count, min, max, steps)

    for table in &[
        "HUAMI_EXTENDED_ACTIVITY_SAMPLE",
        "MI_BAND_ACTIVITY_SAMPLE",
        "HUAMI_ACTIVITY_SAMPLE",
    ] {
        let sql = format!(
            "SELECT DATE(TIMESTAMP, 'unixepoch'), HEART_RATE, STEPS \
             FROM {table} WHERE HEART_RATE > 0 AND HEART_RATE < 255"
        );
        let Ok(mut stmt) = conn.prepare(&sql) else { continue };
        let Ok(rows) = stmt.query_map([], |r| {
            Ok((
                r.get::<_, Option<String>>(0)?,
                r.get::<_, i64>(1)?,
                r.get::<_, Option<i64>>(2).unwrap_or(None).unwrap_or(0),
            ))
        }) else { continue };

        for row in rows.flatten() {
            let (Some(date), hr, steps) = row else { continue };
            let e = hr_accum.entry(date).or_insert((0, 0, hr, hr, 0));
            e.0 += hr;
            e.1 += 1;
            e.2 = e.2.min(hr);
            e.3 = e.3.max(hr);
            e.4 += steps;
        }
        if !hr_accum.is_empty() { break; }
    }

    // ── HRV: Amazfit Cheetah Pro uses GENERIC_HRV_VALUE_SAMPLE (ms timestamps) ─
    let mut hrv_accum: std::collections::HashMap<String, (f64, f64)> =
        std::collections::HashMap::default();

    if let Ok(mut stmt) = conn.prepare(
        "SELECT DATE(TIMESTAMP/1000, 'unixepoch'), VALUE \
         FROM GENERIC_HRV_VALUE_SAMPLE WHERE VALUE > 0",
    ) && let Ok(rows) = stmt.query_map([], |r| {
        Ok((r.get::<_, Option<String>>(0)?, r.get::<_, f64>(1)?))
    }) {
        for row in rows.flatten() {
            let (Some(date), hrv) = row else { continue };
            let e = hrv_accum.entry(date).or_insert((0.0, 0.0));
            e.0 += hrv;
            e.1 += 1.0;
        }
    }

    // ── Merge into output rows ────────────────────────────────────────────────
    let all_dates: std::collections::HashSet<String> = hr_accum
        .keys()
        .chain(hrv_accum.keys())
        .cloned()
        .collect();

    let mut rows: Vec<GbHealthRow> = all_dates
        .into_iter()
        .map(|date| {
            let hr = hr_accum.get(&date);
            let hrv = hrv_accum.get(&date);
            GbHealthRow {
                avg_hr: hr.filter(|e| e.1 > 0).map(|e| e.0 / e.1),
                min_hr: hr.filter(|e| e.1 > 0).map(|e| e.2),
                max_hr: hr.filter(|e| e.1 > 0).map(|e| e.3),
                steps: hr.filter(|e| e.1 > 0).map(|e| e.4),
                hrv_rmssd: hrv.filter(|e| e.1 > 0.0).map(|e| e.0 / e.1),
                date,
            }
        })
        .collect();
    rows.sort_by(|a, b| a.date.cmp(&b.date));
    rows
}

// ── GB debug ──────────────────────────────────────────────────────────────────

/// GB `SQLite` debug dump.
///
/// Extracts the GB database from the zip and returns all table names with
/// columns; for tables matching HRV/HEALTH/ACTIVITY/SLEEP/STRESS also includes
/// 5 sample rows.
///
/// # Errors
/// Returns an error if the zip is not configured or cannot be read.
pub async fn gb_debug(
    State(state): State<AppState>,
) -> AppResult<Json<serde_json::Value>> {
    let zip_path = state
        .config
        .gadgetbridge_zip
        .clone()
        .ok_or_else(|| (StatusCode::SERVICE_UNAVAILABLE, "MONT_GADGETBRIDGE_ZIP not configured".to_string()))?;

    let result = tokio::task::spawn_blocking(move || -> Result<serde_json::Value, String> {
        let file = std::fs::File::open(&zip_path)
            .map_err(|e| format!("Cannot open zip: {e}"))?;
        let mut archive = zip::ZipArchive::new(file)
            .map_err(|e| format!("Invalid zip: {e}"))?;

        let db_bytes = {
            use std::io::Read;
            let mut entry = archive.by_name("database/Gadgetbridge")
                .map_err(|e| format!("Cannot find database/Gadgetbridge: {e}"))?;
            let mut buf = Vec::new();
            entry.read_to_end(&mut buf).map_err(|e| e.to_string())?;
            buf
        };

        let tmp = std::env::temp_dir()
            .join(format!("gb_debug_{}.sqlite", uuid::Uuid::new_v4()));
        std::fs::write(&tmp, &db_bytes).map_err(|e| e.to_string())?;
        let conn = rusqlite::Connection::open(&tmp)
            .map_err(|e| format!("Cannot open DB: {e}"))?;

        // List all tables
        let mut stmt = conn.prepare(
            "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name",
        ).map_err(|e| e.to_string())?;
        let tables: Vec<String> = stmt
            .query_map([], |r| r.get(0))
            .map_err(|e| e.to_string())?
            .flatten()
            .collect();

        let mut output = serde_json::Map::new();
        for table in &tables {
            let upper = table.to_uppercase();
            // For all tables, return column info; for interesting ones, also sample rows
            let cols_sql = format!("PRAGMA table_info({table})");
            let Ok(mut cs) = conn.prepare(&cols_sql) else { continue };
            let cols: Vec<String> = cs
                .query_map([], |r| r.get::<_, String>(1))
                .map(|mapped| mapped.flatten().collect())
                .unwrap_or_default();

            let interesting = upper.contains("HRV")
                || upper.contains("HEALTH")
                || upper.contains("ACTIVITY")
                || upper.contains("SLEEP")
                || upper.contains("STRESS");

            let samples = if interesting {
                let row_sql = format!("SELECT * FROM {table} LIMIT 5");
                let mut rows_json: Vec<serde_json::Value> = Vec::new();
                if let Ok(mut rs) = conn.prepare(&row_sql) {
                    let col_names: Vec<String> = rs
                        .column_names()
                        .iter()
                        .map(|s| (*s).to_string())
                        .collect();
                    if let Ok(mapped) = rs.query_map([], |r| {
                        let mut map = serde_json::Map::new();
                        for (i, name) in col_names.iter().enumerate() {
                            let v = r.get_ref(i).map(|rv| match rv {
                                rusqlite::types::ValueRef::Null => serde_json::Value::Null,
                                rusqlite::types::ValueRef::Integer(n) => serde_json::Value::Number(n.into()),
                                rusqlite::types::ValueRef::Real(f) => {
                                    serde_json::Number::from_f64(f)
                                        .map_or(serde_json::Value::Null, serde_json::Value::Number)
                                }
                                rusqlite::types::ValueRef::Text(t) => {
                                    serde_json::Value::String(String::from_utf8_lossy(t).into_owned())
                                }
                                rusqlite::types::ValueRef::Blob(_) => serde_json::Value::String("<blob>".into()),
                            }).unwrap_or(serde_json::Value::Null);
                            map.insert(name.clone(), v);
                        }
                        Ok(serde_json::Value::Object(map))
                    }) {
                        rows_json = mapped.flatten().collect();
                    }
                }
                serde_json::Value::Array(rows_json)
            } else {
                serde_json::Value::Null
            };

            output.insert(table.clone(), serde_json::json!({
                "columns": cols,
                "samples": samples,
            }));
        }

        let _ = std::fs::remove_file(&tmp);
        Ok(serde_json::Value::Object(output))
    })
    .await
    .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?
    .map_err(|e| (StatusCode::BAD_REQUEST, e))?;

    Ok(Json(result))
}


/// Running activities have `ACTIVITY_KIND & 3 == 1` (bit 0 set, bit 1 clear).
fn load_running_filenames(db_path: &std::path::Path) -> Result<std::collections::HashSet<String>, String> {
    let conn = rusqlite::Connection::open(db_path)
        .map_err(|e| format!("Cannot open Gadgetbridge DB: {e}"))?;
    let mut stmt = conn.prepare(
        "SELECT GPX_TRACK, ACTIVITY_KIND FROM BASE_ACTIVITY_SUMMARY WHERE GPX_TRACK IS NOT NULL",
    ).map_err(|e| e.to_string())?;
    let rows = stmt.query_map([], |row| {
        Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?))
    }).map_err(|e| e.to_string())?;
    let mut set = std::collections::HashSet::new();
    for r in rows {
        let (path, kind) = r.map_err(|e| e.to_string())?;
        if kind & 3 == 1 {
            let fname = path.rsplit('/').next().unwrap_or(&path).to_owned();
            set.insert(fname);
        }
    }
    Ok(set)
}

/// Import a single parsed GPX file into the runs table.
async fn import_gpx_run(
    name: &str,
    parsed: &ParsedRun,
    pool: &sqlx::SqlitePool,
) -> Result<(), String> {
    let route_json = serde_json::to_string(&parsed.route)
        .map_err(|e| format!("{name}: {e}"))?;
    sqlx::query(
        "INSERT INTO runs \
         (started_at, duration_s, distance_m, elevation_gain_m, avg_hr, max_hr, route_json, source_file, avg_cadence, avg_stride_m) \
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?) \
         ON CONFLICT(source_file) WHERE source_file IS NOT NULL DO UPDATE SET \
           started_at = excluded.started_at, \
           duration_s = excluded.duration_s, \
           distance_m = excluded.distance_m, \
           elevation_gain_m = excluded.elevation_gain_m, \
           avg_hr = excluded.avg_hr, \
           max_hr = excluded.max_hr, \
           route_json = excluded.route_json, \
           avg_cadence = excluded.avg_cadence, \
           avg_stride_m = excluded.avg_stride_m",
    )
    .bind(&parsed.started_at)
    .bind(parsed.duration_s)
    .bind(parsed.distance_m)
    .bind(parsed.elevation_gain_m)
    .bind(parsed.avg_hr)
    .bind(parsed.max_hr)
    .bind(&route_json)
    .bind(name)
    .bind(parsed.avg_cadence)
    .bind(parsed.avg_stride_m)
    .execute(pool)
    .await
    .map_err(|e| format!("{name}: {e}"))?;
    Ok(())
}

/// Core sync logic. Called by the HTTP handler and the background scheduler.
/// # Errors
/// Returns an error string if the zip cannot be opened or parsed.
pub async fn perform_sync(state: &AppState) -> Result<SyncResult, String> {
    let zip_path = state
        .config
        .gadgetbridge_zip
        .clone()
        .ok_or_else(|| "MONT_GADGETBRIDGE_ZIP not configured".to_string())?;

    let (running_filenames, gpx_files, health_rows) = tokio::task::spawn_blocking(move || -> Result<_, String> {
        let file = std::fs::File::open(&zip_path)
            .map_err(|e| format!("Cannot open zip {}: {e}", zip_path.display()))?;
        let mut archive = zip::ZipArchive::new(file)
            .map_err(|e| format!("Invalid zip: {e}"))?;

        // Extract the Gadgetbridge SQLite DB bytes from the zip.
        let db_bytes = {
            use std::io::Read;
            let mut entry = archive.by_name("database/Gadgetbridge")
                .map_err(|e| format!("Cannot find database/Gadgetbridge in zip: {e}"))?;
            let mut buf = Vec::new();
            entry.read_to_end(&mut buf).map_err(|e| e.to_string())?;
            buf
        };

        // Write to a temp file so rusqlite can open it.
        let tmp_path = std::env::temp_dir()
            .join(format!("gadgetbridge_{}.sqlite", uuid::Uuid::new_v4()));
        std::fs::write(&tmp_path, &db_bytes).map_err(|e| e.to_string())?;
        let running_filenames = load_running_filenames(&tmp_path);
        let health_rows = extract_daily_health(&tmp_path);
        let _ = std::fs::remove_file(&tmp_path);
        let running_filenames = running_filenames?;

        // Extract GPX files from the files/ directory in the zip.
        let mut gpx_files: Vec<(String, Vec<u8>)> = Vec::new();
        for i in 0..archive.len() {
            use std::io::Read;
            let mut entry = archive.by_index(i).map_err(|e| e.to_string())?;
            let name = entry.name().to_owned();
            if !name.starts_with("files/") { continue; }
            let basename = name.rsplit('/').next().unwrap_or(&name).to_owned();
            if !basename.to_ascii_lowercase().ends_with(".gpx") { continue; }
            let mut buf = Vec::new();
            entry.read_to_end(&mut buf).map_err(|e| e.to_string())?;
            gpx_files.push((basename, buf));
        }

        Ok((running_filenames, gpx_files, health_rows))
    })
    .await
    .map_err(|e| e.to_string())??;

    let mut imported = 0usize;
    let mut errors: Vec<String> = Vec::new();

    for (name, bytes) in gpx_files {
        // Skip any file not listed as a running activity in the Gadgetbridge DB.
        if !running_filenames.contains(&name) {
            continue;
        }

        match parse_gpx(&bytes) {
            Err(e) if e.to_string().contains("no track points") => {} // not a run, skip silently
            Err(e) => {
                errors.push(format!("{name}: {e}"));
            }
            Ok(parsed) => {
                // Skip non-running activities based on GPX <type> field (when present)
                if !is_running_activity(parsed.activity_type.as_deref()) {
                    continue;
                }
                match import_gpx_run(&name, &parsed, &state.pool).await {
                    Ok(()) => imported += 1,
                    Err(e) => errors.push(e),
                }
            }
        }
    }

    // ── Upsert daily health rows ──────────────────────────────────────────────
    for row in &health_rows {
        let _ = sqlx::query(
            "INSERT INTO daily_health (date, avg_hr, min_hr, max_hr, hrv_rmssd, steps) \
             VALUES (?, ?, ?, ?, ?, ?) \
             ON CONFLICT(date) DO UPDATE SET \
               avg_hr    = excluded.avg_hr, \
               min_hr    = excluded.min_hr, \
               max_hr    = excluded.max_hr, \
               hrv_rmssd = excluded.hrv_rmssd, \
               steps     = excluded.steps",
        )
        .bind(&row.date)
        .bind(row.avg_hr)
        .bind(row.min_hr)
        .bind(row.max_hr)
        .bind(row.hrv_rmssd)
        .bind(row.steps)
        .execute(&state.pool)
        .await;
    }

    Ok(SyncResult { imported, health_days: health_rows.len(), errors })
}

/// # Errors
/// Returns `SERVICE_UNAVAILABLE` if `MONT_GADGETBRIDGE_ZIP` is not configured,
/// or a database error.
pub async fn sync_gadgetbridge(
    State(state): State<AppState>,
) -> AppResult<Json<SyncResult>> {
    if state.config.gadgetbridge_zip.is_none() {
        return Err((StatusCode::SERVICE_UNAVAILABLE, "MONT_GADGETBRIDGE_ZIP not configured".to_string()).into());
    }
    perform_sync(&state)
        .await
        .map(Json)
        .map_err(|e| (StatusCode::BAD_REQUEST, e).into())
}

// ── Heatmap ───────────────────────────────────────────────────────────────────

/// Returns all valid run routes as arrays of `[lat, lon]` pairs for map overlay.
///
/// # Errors
/// Returns an error if the database query fails.
pub async fn heatmap(
    State(state): State<AppState>,
) -> AppResult<Json<Vec<Vec<[f64; 2]>>>> {
    #[derive(sqlx::FromRow)]
    struct Row { route_json: String }

    #[derive(serde::Deserialize)]
    struct Pt { lat: f64, lon: f64 }

    let rows: Vec<Row> = sqlx::query_as(
        "SELECT route_json FROM runs WHERE is_invalid = 0 AND route_json != '[]'",
    )
    .fetch_all(&state.pool)
    .await?;

    let routes = rows
        .iter()
        .filter_map(|r| {
            serde_json::from_str::<Vec<Pt>>(&r.route_json)
                .ok()
                .map(|pts| pts.iter().map(|p| [p.lat, p.lon]).collect::<Vec<_>>())
        })
        .filter(|pts| !pts.is_empty())
        .collect();

    Ok(Json(routes))
}

// ── Personal records ─────────────────────────────────────────────────────────

#[derive(Serialize)]
pub struct PersonalRecord {
    pub distance_label: String,
    pub run_id: i64,
    pub run_date: String,
    pub estimated_seconds: f64,
}

/// Returns the best run (by estimated time at pace) for each standard distance.
/// A run qualifies if its distance is >= 95% of the target distance.
///
/// # Errors
/// Returns an error if the database query fails.
pub async fn personal_records(
    State(state): State<AppState>,
) -> AppResult<Json<Vec<PersonalRecord>>> {
    #[derive(sqlx::FromRow)]
    struct RunRow {
        id: i64,
        started_at: String,
        duration_s: i64,
        distance_m: f64,
    }

    let runs = sqlx::query_as::<_, RunRow>(
        "SELECT id, started_at, duration_s, distance_m FROM runs WHERE is_invalid = 0 ORDER BY started_at",
    )
    .fetch_all(&state.pool)
    .await?;

    let targets: &[(&str, f64)] = &[
        ("1 km", 1_000.0),
        ("5 km", 5_000.0),
        ("10 km", 10_000.0),
        ("Half marathon", 21_097.5),
        ("Marathon", 42_195.0),
    ];

    let mut prs = Vec::new();
    for (label, target_m) in targets {
        let best = runs
            .iter()
            .filter(|r| r.distance_m >= target_m * 0.95)
            .min_by(|a, b| {
                let pace_a = f64::from(i32::try_from(a.duration_s).unwrap_or(i32::MAX)) * target_m / a.distance_m;
                let pace_b = f64::from(i32::try_from(b.duration_s).unwrap_or(i32::MAX)) * target_m / b.distance_m;
                pace_a.partial_cmp(&pace_b).unwrap_or(std::cmp::Ordering::Equal)
            });
        if let Some(run) = best {
            prs.push(PersonalRecord {
                distance_label: (*label).to_string(),
                run_id: run.id,
                run_date: run.started_at.clone(),
                estimated_seconds: f64::from(i32::try_from(run.duration_s).unwrap_or(i32::MAX)) * target_m / run.distance_m,
            });
        }
    }

    Ok(Json(prs))
}

#[derive(Deserialize)]
pub struct SetInvalidBody {
    pub is_invalid: bool,
}

/// Toggle the `is_invalid` flag on a run (keeps it in the DB so re-import won't duplicate it).
///
/// # Errors
/// Returns `NOT_FOUND` if the run doesn't exist, or a database error.
pub async fn set_invalid(
    State(state): State<AppState>,
    Path(id): Path<i64>,
    Json(body): Json<SetInvalidBody>,
) -> AppResult<StatusCode> {
    let rows = sqlx::query("UPDATE runs SET is_invalid = ? WHERE id = ?")
        .bind(body.is_invalid)
        .bind(id)
        .execute(&state.pool)
        .await?
        .rows_affected();
    if rows == 0 {
        return Err((StatusCode::NOT_FOUND, "Run not found".to_string()).into());
    }
    Ok(StatusCode::NO_CONTENT)
}
