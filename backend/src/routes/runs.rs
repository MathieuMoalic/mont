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

    let route = points
        .into_iter()
        .map(|p| RoutePoint { lat: p.lat, lon: p.lon, ele: p.ele, hr: p.hr })
        .collect();

    Ok(ParsedRun { started_at, duration_s, distance_m, elevation_gain_m, avg_hr, max_hr, route })
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

    let route_json = serde_json::to_string(&parsed.route)
        .map_err(anyhow::Error::from)?;

    let run = sqlx::query_as::<_, RunSummary>(
        "INSERT INTO runs \
         (started_at, duration_s, distance_m, elevation_gain_m, avg_hr, max_hr, route_json) \
         VALUES (?, ?, ?, ?, ?, ?, ?) \
         RETURNING id, started_at, duration_s, distance_m, elevation_gain_m, avg_hr, max_hr, notes",
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
        "SELECT id, started_at, duration_s, distance_m, elevation_gain_m, avg_hr, max_hr, notes \
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
    pub skipped: usize,
    pub errors: Vec<String>,
}

/// # Errors
/// Returns `SERVICE_UNAVAILABLE` if no zip path is configured,
/// `NOT_FOUND` if the zip file doesn't exist, or a database error.
pub async fn sync_gadgetbridge(
    State(state): State<AppState>,
) -> AppResult<Json<SyncResult>> {
    let zip_path = state
        .config
        .gadgetbridge_zip
        .clone()
        .ok_or_else(|| (StatusCode::SERVICE_UNAVAILABLE, "MONT_GADGETBRIDGE_ZIP not configured".to_string()))?;

    // Read all GPX files from zip in a blocking thread (zip::ZipArchive is not Send)
    let gpx_files: Vec<(String, Vec<u8>)> = tokio::task::spawn_blocking(move || {
        let file = std::fs::File::open(&zip_path)
            .map_err(|e| format!("Cannot open zip: {e}"))?;
        let mut archive = zip::ZipArchive::new(file)
            .map_err(|e| format!("Invalid zip: {e}"))?;
        let mut out = Vec::new();
        for i in 0..archive.len() {
            let mut entry = archive.by_index(i).map_err(|e| e.to_string())?;
            let name = entry.name().to_owned();
            if !name.to_ascii_lowercase().ends_with(".gpx") { continue; }
            let mut bytes = Vec::new();
            std::io::Read::read_to_end(&mut entry, &mut bytes).map_err(|e| e.to_string())?;
            out.push((name, bytes));
        }
        Ok::<_, String>(out)
    })
    .await
    .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?
    .map_err(|e| (StatusCode::BAD_REQUEST, e))?;

    let mut imported = 0usize;
    let mut skipped = 0usize;
    let mut errors: Vec<String> = Vec::new();

    for (name, bytes) in gpx_files {
        let exists: bool = sqlx::query_scalar(
            "SELECT EXISTS(SELECT 1 FROM runs WHERE source_file = ?)",
        )
        .bind(&name)
        .fetch_one(&state.pool)
        .await?;

        if exists {
            skipped += 1;
            continue;
        }

        match parse_gpx(&bytes) {
            Err(e) => {
                errors.push(format!("{name}: {e}"));
            }
            Ok(parsed) => {
                let route_json = match serde_json::to_string(&parsed.route) {
                    Ok(j) => j,
                    Err(e) => { errors.push(format!("{name}: {e}")); continue; }
                };
                let result = sqlx::query(
                    "INSERT OR IGNORE INTO runs \
                     (started_at, duration_s, distance_m, elevation_gain_m, avg_hr, max_hr, route_json, source_file) \
                     VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
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
                    Ok(r) if r.rows_affected() > 0 => imported += 1,
                    Ok(_) => skipped += 1,
                    Err(e) => errors.push(format!("{name}: {e}")),
                }
            }
        }
    }

    Ok(Json(SyncResult { imported, skipped, errors }))
}
