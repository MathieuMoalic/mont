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
}

// ── GPX parsing ───────────────────────────────────────────────────────────────

struct TrackPoint {
    lat: f64,
    lon: f64,
    ele: Option<f64>,
    time_secs: Option<i64>,
    hr: Option<i64>,
}

struct ParsedRun {
    started_at: String,
    duration_s: i64,
    distance_m: f64,
    elevation_gain_m: Option<f64>,
    avg_hr: Option<i64>,
    max_hr: Option<i64>,
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

fn parse_gpx(data: &[u8]) -> anyhow::Result<ParsedRun> {
    let text = std::str::from_utf8(data)?;
    let doc = roxmltree::Document::parse(text)?;

    // Extract activity type from <trk><type> (e.g. "running", "cycling")
    let activity_type = doc
        .descendants()
        .find(|n| n.tag_name().name() == "trk")
        .and_then(|trk| trk.children().find(|n| n.tag_name().name() == "type"))
        .and_then(|n| n.text())
        .map(|t| t.trim().to_lowercase());

    let mut points: Vec<TrackPoint> = Vec::new();

    for node in doc.descendants() {
        if node.tag_name().name() != "trkpt" {
            continue;
        }
        let lat: f64 = node
            .attribute("lat")
            .ok_or_else(|| anyhow::anyhow!("trkpt missing lat"))?
            .parse()?;
        let lon: f64 = node
            .attribute("lon")
            .ok_or_else(|| anyhow::anyhow!("trkpt missing lon"))?
            .parse()?;

        let ele = node
            .children()
            .find(|n| n.tag_name().name() == "ele")
            .and_then(|n| n.text())
            .and_then(|t| t.parse::<f64>().ok());

        let time_secs = node
            .children()
            .find(|n| n.tag_name().name() == "time")
            .and_then(|n| n.text())
            .and_then(|t| parse_timestamp(t).ok());

        let hr = node
            .descendants()
            .find(|n| n.tag_name().name() == "hr")
            .and_then(|n| n.text())
            .and_then(|t| t.parse::<i64>().ok());

        points.push(TrackPoint { lat, lon, ele, time_secs, hr });
    }

    anyhow::ensure!(!points.is_empty(), "GPX contains no track points");

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

    let duration_s = match (
        points.first().and_then(|p| p.time_secs),
        points.last().and_then(|p| p.time_secs),
    ) {
        (Some(start), Some(end)) => (end - start).max(0),
        _ => 0,
    };

    let distance_m: f64 = points
        .windows(2)
        .map(|w| haversine_m(w[0].lat, w[0].lon, w[1].lat, w[1].lon))
        .sum();

    let elevation_gain_m: Option<f64> = {
        let elevations: Vec<f64> = points.iter().filter_map(|p| p.ele).collect();
        if elevations.len() >= 2 {
            let gain: f64 = elevations
                .windows(2)
                .filter_map(|w| {
                    let d = w[1] - w[0];
                    if d > 0.0 { Some(d) } else { None }
                })
                .sum();
            Some(gain)
        } else {
            None
        }
    };

    let hr_values: Vec<i64> = points.iter().filter_map(|p| p.hr).collect();
    let avg_hr = if hr_values.is_empty() {
        None
    } else {
        #[allow(clippy::cast_possible_truncation)]
        Some(hr_values.iter().sum::<i64>() / i64::try_from(hr_values.len()).unwrap_or(1))
    };
    let max_hr = hr_values.into_iter().max();

    let route = {
        let t0 = points.first().and_then(|p| p.time_secs);
        points
            .into_iter()
            .map(|p| RoutePoint {
                lat: p.lat,
                lon: p.lon,
                ele: p.ele,
                hr: p.hr,
                t: p.time_secs.and_then(|ts| t0.map(|t0| ts - t0)),
            })
            .collect()
    };

    Ok(ParsedRun { started_at, duration_s, distance_m, elevation_gain_m, avg_hr, max_hr, route, activity_type })
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
         (started_at, duration_s, distance_m, elevation_gain_m, avg_hr, max_hr, route_json) \
         VALUES (?, ?, ?, ?, ?, ?, ?) \
         RETURNING id, started_at, duration_s, distance_m, elevation_gain_m, avg_hr, max_hr, notes, is_invalid",
    )
    .bind(&parsed.started_at)
    .bind(parsed.duration_s)
    .bind(parsed.distance_m)
    .bind(parsed.elevation_gain_m)
    .bind(parsed.avg_hr)
    .bind(parsed.max_hr)
    .bind(&route_json)
    .fetch_one(&state.pool)
    .await?;

    Ok((StatusCode::CREATED, Json(run)))
}

/// # Errors
/// Returns an error if the database query fails.
pub async fn list_runs(State(state): State<AppState>) -> AppResult<Json<Vec<RunSummary>>> {
    let runs = sqlx::query_as::<_, RunSummary>(
        "SELECT id, started_at, duration_s, distance_m, elevation_gain_m, avg_hr, max_hr, notes, is_invalid \
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

#[derive(Serialize)]
pub struct SyncResult {
    pub imported: usize,
    pub errors: Vec<String>,
}

/// Load running GPX filenames from the Gadgetbridge `SQLite` DB.
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

/// # Errors
/// Returns `SERVICE_UNAVAILABLE` if `MONT_GADGETBRIDGE_ZIP` is not configured,
/// or a database error.
pub async fn sync_gadgetbridge(
    State(state): State<AppState>,
) -> AppResult<Json<SyncResult>> {
    let zip_path = state
        .config
        .gadgetbridge_zip
        .clone()
        .ok_or_else(|| (StatusCode::SERVICE_UNAVAILABLE, "MONT_GADGETBRIDGE_ZIP not configured".to_string()))?;

    let (running_filenames, gpx_files) = tokio::task::spawn_blocking(move || -> Result<_, String> {
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

        Ok((running_filenames, gpx_files))
    })
    .await
    .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?
    .map_err(|e| (StatusCode::BAD_REQUEST, e))?;

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
                let route_json = match serde_json::to_string(&parsed.route) {
                    Ok(j) => j,
                    Err(e) => { errors.push(format!("{name}: {e}")); continue; }
                };
                let result = sqlx::query(
                    "INSERT INTO runs \
                     (started_at, duration_s, distance_m, elevation_gain_m, avg_hr, max_hr, route_json, source_file) \
                     VALUES (?, ?, ?, ?, ?, ?, ?, ?) \
                     ON CONFLICT(source_file) WHERE source_file IS NOT NULL DO UPDATE SET \
                       started_at = excluded.started_at, \
                       duration_s = excluded.duration_s, \
                       distance_m = excluded.distance_m, \
                       elevation_gain_m = excluded.elevation_gain_m, \
                       avg_hr = excluded.avg_hr, \
                       max_hr = excluded.max_hr, \
                       route_json = excluded.route_json",
                )
                .bind(&parsed.started_at)
                .bind(parsed.duration_s)
                .bind(parsed.distance_m)
                .bind(parsed.elevation_gain_m)
                .bind(parsed.avg_hr)
                .bind(parsed.max_hr)
                .bind(&route_json)
                .bind(&name)
                .execute(&state.pool)
                .await;
                match result {
                    Ok(_) => imported += 1,
                    Err(e) => errors.push(format!("{name}: {e}")),
                }
            }
        }
    }

    Ok(Json(SyncResult { imported, errors }))
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
