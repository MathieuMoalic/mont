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
    pub weather_temp_c: Option<f64>,
    pub weather_wind_kph: Option<f64>,
    pub weather_precip_mm: Option<f64>,
    pub weather_code: Option<i64>,
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
    pub weather_temp_c: Option<f64>,
    pub weather_wind_kph: Option<f64>,
    pub weather_precip_mm: Option<f64>,
    pub weather_code: Option<i64>,
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
    weather_temp_c: Option<f64>,
    weather_wind_kph: Option<f64>,
    weather_precip_mm: Option<f64>,
    weather_code: Option<i64>,
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

    // Step length (m) = speed_m_s * 60 / cadence_spm  (cadence = total steps/min)
    let avg_stride_m = avg_cadence.and_then(|cad| {
        let speed_values: Vec<f64> = points.iter().filter_map(|p| p.speed).collect();
        if speed_values.is_empty() || cad == 0 {
            None
        } else {
            let avg_speed = speed_values.iter().sum::<f64>()
                / f64::from(u32::try_from(speed_values.len()).unwrap_or(1));
            #[allow(clippy::cast_precision_loss)]
            Some(avg_speed * 60.0 / cad as f64)
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
        weather_temp_c: None, weather_wind_kph: None,
        weather_precip_mm: None, weather_code: None,
    })
}

// ── FIT parsing ───────────────────────────────────────────────────────────────

const SEMICIRCLES_TO_DEG: f64 = 180.0 / 2_147_483_648.0;

fn fit_value_as_f64(v: &fitparser::Value) -> Option<f64> {
    use std::convert::TryInto;
    v.clone().try_into().ok()
}

fn fit_value_as_i64(v: &fitparser::Value) -> Option<i64> {
    use std::convert::TryInto;
    v.clone().try_into().ok()
}

fn fit_field<'a>(record: &'a fitparser::FitDataRecord, name: &str) -> Option<&'a fitparser::Value> {
    record.fields().iter().find(|f| f.name() == name).map(fitparser::FitDataField::value)
}

fn parse_fit(data: &[u8]) -> anyhow::Result<ParsedRun> {
    let records = fitparser::from_bytes(data)?;

    // Check activity type from session record (default to running if absent)
    let sport: Option<String> = records.iter()
        .filter(|r| r.kind().to_string() == "session")
        .find_map(|r| {
            if let Some(fitparser::Value::String(s)) = fit_field(r, "sport") {
                Some(s.clone())
            } else {
                None
            }
        });

    if !is_running_activity(sport.as_deref()) {
        anyhow::bail!(
            "Activity type '{}' is not a running activity",
            sport.as_deref().unwrap_or("unknown")
        );
    }

    let mut points: Vec<TrackPoint> = Vec::new();

    for record in records.iter().filter(|r| r.kind().to_string() == "record") {
        let lat = fit_field(record, "position_lat")
            .and_then(fit_value_as_i64)
            .map(|v| {
                #[allow(clippy::cast_precision_loss)]
                let f = v as f64;
                f * SEMICIRCLES_TO_DEG
            });
        let lon = fit_field(record, "position_long")
            .and_then(fit_value_as_i64)
            .map(|v| {
                #[allow(clippy::cast_precision_loss)]
                let f = v as f64;
                f * SEMICIRCLES_TO_DEG
            });

        let Some((lat, lon)) = lat.zip(lon) else { continue };

        let ele = fit_field(record, "enhanced_altitude")
            .or_else(|| fit_field(record, "altitude"))
            .and_then(fit_value_as_f64);

        let hr = fit_field(record, "heart_rate")
            .and_then(fit_value_as_i64)
            .filter(|&v| v > 0 && v < 255);

        // FIT cadence is strides/min; multiply by 2 for total steps/min
        let cad = fit_field(record, "cadence")
            .and_then(fit_value_as_i64)
            .filter(|&v| v > 0)
            .map(|v| v * 2);

        let speed = fit_field(record, "enhanced_speed")
            .or_else(|| fit_field(record, "speed"))
            .and_then(fit_value_as_f64)
            .filter(|&v| v > 0.0);

        let time_secs = record.fields().iter()
            .find(|f| f.name() == "timestamp")
            .and_then(|f| {
                if let fitparser::Value::Timestamp(dt) = f.value() {
                    Some(dt.timestamp())
                } else {
                    None
                }
            });

        points.push(TrackPoint { lat, lon, ele, time_secs, hr, cad, speed });
    }

    anyhow::ensure!(!points.is_empty(), "FIT file contains no GPS track points");

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
        route, activity_type: sport,
        weather_temp_c: None, weather_wind_kph: None,
        weather_precip_mm: None, weather_code: None,
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

    let mut parsed = parse_gpx(&bytes)
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

    // Fetch weather for the first route point
    if let Some(first) = parsed.route.first()
        && let Ok(ts) = parse_timestamp(&parsed.started_at)
        && let Some(w) = crate::weather::fetch_weather(
            &state.http, first.lat, first.lon, ts,
        ).await
    {
        parsed.weather_temp_c    = Some(w.temp_c);
        parsed.weather_wind_kph  = Some(w.wind_kph);
        parsed.weather_precip_mm = Some(w.precip_mm);
        parsed.weather_code      = Some(w.code);
    }

    let route_json = serde_json::to_string(&parsed.route)
        .map_err(anyhow::Error::from)?;

    let run = sqlx::query_as::<_, RunSummary>(
        "INSERT INTO runs \
         (started_at, duration_s, distance_m, elevation_gain_m, avg_hr, max_hr, route_json, avg_cadence, avg_stride_m, \
          weather_temp_c, weather_wind_kph, weather_precip_mm, weather_code) \
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) \
         RETURNING id, started_at, duration_s, distance_m, elevation_gain_m, avg_hr, max_hr, notes, is_invalid, \
                   avg_cadence, avg_stride_m, weather_temp_c, weather_wind_kph, weather_precip_mm, weather_code",
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
    .bind(parsed.weather_temp_c)
    .bind(parsed.weather_wind_kph)
    .bind(parsed.weather_precip_mm)
    .bind(parsed.weather_code)
    .fetch_one(&state.pool)
    .await?;

    Ok((StatusCode::CREATED, Json(run)))
}

/// Import a run from a Garmin FIT file (e.g., directly downloaded from an Amazfit watch).
///
/// # Errors
/// Returns `BAD_REQUEST` if the multipart body is malformed or missing the `file` field,
/// `UNPROCESSABLE_ENTITY` if the FIT file cannot be parsed or is not a running activity,
/// or a database error.
pub async fn import_run_fit(
    State(state): State<AppState>,
    mut multipart: Multipart,
) -> AppResult<(StatusCode, Json<RunSummary>)> {
    let mut fit_bytes: Option<Vec<u8>> = None;

    while let Some(field) = multipart
        .next_field()
        .await
        .map_err(|e| (StatusCode::BAD_REQUEST, e.body_text()))?
    {
        if field.name() == Some("file") {
            fit_bytes = Some(
                field
                    .bytes()
                    .await
                    .map_err(|e| (StatusCode::BAD_REQUEST, e.body_text()))?
                    .to_vec(),
            );
        }
    }

    let bytes = fit_bytes
        .ok_or_else(|| (StatusCode::BAD_REQUEST, "Missing `file` field".to_string()))?;

    let mut parsed = parse_fit(&bytes)
        .map_err(|e| (StatusCode::UNPROCESSABLE_ENTITY, e.to_string()))?;

    // Fetch weather for the first route point
    if let Some(first) = parsed.route.first()
        && let Ok(ts) = parse_timestamp(&parsed.started_at)
        && let Some(w) = crate::weather::fetch_weather(
            &state.http, first.lat, first.lon, ts,
        ).await
    {
        parsed.weather_temp_c    = Some(w.temp_c);
        parsed.weather_wind_kph  = Some(w.wind_kph);
        parsed.weather_precip_mm = Some(w.precip_mm);
        parsed.weather_code      = Some(w.code);
    }

    let route_json = serde_json::to_string(&parsed.route)
        .map_err(anyhow::Error::from)?;

    let run = sqlx::query_as::<_, RunSummary>(
        "INSERT INTO runs \
         (started_at, duration_s, distance_m, elevation_gain_m, avg_hr, max_hr, route_json, avg_cadence, avg_stride_m, \
          weather_temp_c, weather_wind_kph, weather_precip_mm, weather_code) \
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) \
         RETURNING id, started_at, duration_s, distance_m, elevation_gain_m, avg_hr, max_hr, notes, is_invalid, \
                   avg_cadence, avg_stride_m, weather_temp_c, weather_wind_kph, weather_precip_mm, weather_code",
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
    .bind(parsed.weather_temp_c)
    .bind(parsed.weather_wind_kph)
    .bind(parsed.weather_precip_mm)
    .bind(parsed.weather_code)
    .fetch_one(&state.pool)
    .await?;

    Ok((StatusCode::CREATED, Json(run)))
}

/// # Errors
/// Returns an error if the database query fails.
pub async fn list_runs(State(state): State<AppState>) -> AppResult<Json<Vec<RunSummary>>> {
    let runs = sqlx::query_as::<_, RunSummary>(
        "SELECT id, started_at, duration_s, distance_m, elevation_gain_m, avg_hr, max_hr, notes, is_invalid, \
                avg_cadence, avg_stride_m, weather_temp_c, weather_wind_kph, weather_precip_mm, weather_code \
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
        weather_temp_c: Option<f64>,
        weather_wind_kph: Option<f64>,
        weather_precip_mm: Option<f64>,
        weather_code: Option<i64>,
    }

    let row = sqlx::query_as::<_, RunRow>(
        "SELECT id, started_at, duration_s, distance_m, elevation_gain_m, \
                avg_hr, max_hr, notes, route_json, \
                weather_temp_c, weather_wind_kph, weather_precip_mm, weather_code \
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
        weather_temp_c: row.weather_temp_c,
        weather_wind_kph: row.weather_wind_kph,
        weather_precip_mm: row.weather_precip_mm,
        weather_code: row.weather_code,
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
// ── BLE summary import ────────────────────────────────────────────────────────

#[derive(Deserialize)]
pub struct BleSummaryInput {
    /// ISO 8601 UTC, e.g. "2025-11-28T07:19:42Z"
    pub started_at: String,
    pub duration_seconds: i64,
    pub distance_meters: f64,
    pub avg_hr: Option<i64>,
    pub max_hr: Option<i64>,
}

/// Import a run from a BLE sports-summary (Amazfit Cheetah Pro).
///
/// If a run with the same `started_at` already exists it is returned as-is
/// (idempotent — safe to call multiple times for the same workout).
///
/// # Errors
/// Returns `BAD_REQUEST` if the body is malformed, or a database error.
pub async fn import_ble_summary(
    State(state): State<AppState>,
    Json(body): Json<BleSummaryInput>,
) -> AppResult<(StatusCode, Json<RunSummary>)> {
    // Idempotency: return existing run if already imported.
    let existing: Option<RunSummary> = sqlx::query_as(
        "SELECT id, started_at, duration_s, distance_m, elevation_gain_m, avg_hr, max_hr, \
                notes, is_invalid, avg_cadence, avg_stride_m, \
                weather_temp_c, weather_wind_kph, weather_precip_mm, weather_code \
         FROM runs WHERE started_at = ? LIMIT 1",
    )
    .bind(&body.started_at)
    .fetch_optional(&state.pool)
    .await?;

    if let Some(run) = existing {
        return Ok((StatusCode::OK, Json(run)));
    }

    let run = sqlx::query_as::<_, RunSummary>(
        "INSERT INTO runs (started_at, duration_s, distance_m, avg_hr, max_hr, route_json) \
         VALUES (?, ?, ?, ?, ?, '[]') \
         RETURNING id, started_at, duration_s, distance_m, elevation_gain_m, avg_hr, max_hr, \
                   notes, is_invalid, avg_cadence, avg_stride_m, \
                   weather_temp_c, weather_wind_kph, weather_precip_mm, weather_code",
    )
    .bind(&body.started_at)
    .bind(body.duration_seconds)
    .bind(body.distance_meters)
    .bind(body.avg_hr)
    .bind(body.max_hr)
    .fetch_one(&state.pool)
    .await?;

    Ok((StatusCode::CREATED, Json(run)))
}

// ── BLE route update ──────────────────────────────────────────────────────────

#[derive(Deserialize)]
pub struct BleRouteInput {
    pub started_at: String,
    pub route: Vec<RoutePoint>,
    pub avg_cadence: Option<i64>,
    pub avg_stride_m: Option<f64>,
}

/// Update the GPS route for a run that was previously imported via BLE summary.
///
/// Looks up the run by `started_at` (must match exactly).
/// Replaces the existing `route_json` and computes `elevation_gain_m` from the
/// route points. Also stores `avg_cadence` and `avg_stride_m` if provided.
///
/// # Errors
/// Returns `NOT_FOUND` if no run with that timestamp exists, or a database error.
pub async fn patch_ble_route(
    State(state): State<AppState>,
    Json(body): Json<BleRouteInput>,
) -> AppResult<StatusCode> {
    let route_json = serde_json::to_string(&body.route)
        .map_err(|e| (StatusCode::BAD_REQUEST, e.to_string()))?;

    // Compute elevation gain from the route points.
    let elevations: Vec<f64> = body.route.iter().filter_map(|p| p.ele).collect();
    let elevation_gain_m: Option<f64> = if elevations.len() >= 2 {
        let gain: f64 = elevations.windows(2)
            .filter_map(|w| { let d = w[1] - w[0]; if d > 0.0 { Some(d) } else { None } })
            .sum();
        Some(gain)
    } else {
        None
    };

    // Fetch weather using first route point + run start time.
    let weather = if let Some(first) = body.route.first()
        && let Ok(ts) = parse_timestamp(&body.started_at)
    {
        crate::weather::fetch_weather(&state.http, first.lat, first.lon, ts).await
    } else {
        None
    };

    let rows = sqlx::query(
        "UPDATE runs SET route_json = ?, elevation_gain_m = ?, avg_cadence = ?, avg_stride_m = ?, \
         weather_temp_c = ?, weather_wind_kph = ?, weather_precip_mm = ?, weather_code = ? \
         WHERE started_at = ?",
    )
    .bind(&route_json)
    .bind(elevation_gain_m)
    .bind(body.avg_cadence)
    .bind(body.avg_stride_m)
    .bind(weather.as_ref().map(|w| w.temp_c))
    .bind(weather.as_ref().map(|w| w.wind_kph))
    .bind(weather.as_ref().map(|w| w.precip_mm))
    .bind(weather.as_ref().map(|w| w.code))
    .bind(&body.started_at)
    .execute(&state.pool)
    .await?
    .rows_affected();

    if rows == 0 {
        return Err((StatusCode::NOT_FOUND, "No run found with that started_at".to_string()).into());
    }
    Ok(StatusCode::NO_CONTENT)
}

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
