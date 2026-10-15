use axum::{
    Json,
    extract::{Multipart, Path, Query, State},
    http::StatusCode,
};
use serde::{Deserialize, Serialize};

use crate::{error::AppResult, models::AppState, pagination::Pagination};

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
    pub calories: Option<i64>,
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
    pub calories: Option<i64>,
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
    calories: Option<i64>,
}

fn is_running_activity(activity_type: Option<&str>) -> bool {
    // No type field → assume running (e.g. manually-created GPX files)
    activity_type.is_none_or(|t| {
        let normalized = t.trim().to_ascii_lowercase();
        matches!(
            normalized.as_str(),
            "running" | "trail_running" | "trail running" | "run" | "jogging" | "jog"
        )
    })
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

    RunStats {
        avg_hr,
        max_hr,
        avg_cadence,
        avg_stride_m,
    }
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
    let child_text = |name: &str| {
        node.children()
            .find(|n| n.tag_name().name() == name)
            .and_then(|n| n.text())
    };
    let ext_text = |name: &str| {
        node.descendants()
            .find(|n| n.tag_name().name() == name)
            .and_then(|n| n.text())
    };
    let ele = child_text("ele").and_then(|t| t.parse::<f64>().ok());
    let time_secs = child_text("time").and_then(|t| parse_timestamp(t).ok());
    let hr = ext_text("hr").and_then(|t| t.parse::<i64>().ok());
    let cad = ext_text("cad")
        .and_then(|t| t.parse::<i64>().ok())
        .filter(|&c| c > 0);
    let speed = ext_text("speed")
        .and_then(|t| t.parse::<f64>().ok())
        .filter(|&s| s > 0.0);
    Ok(TrackPoint {
        lat,
        lon,
        ele,
        time_secs,
        hr,
        cad,
        speed,
    })
}

/// Maximum gap (seconds) between points before we consider it a pause.
const PAUSE_THRESHOLD_SECS: i64 = 60;

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

    // Calculate active time by summing segment durations, excluding pauses.
    // A pause is detected when the gap between consecutive points exceeds the threshold.
    let duration_s: i64 = points
        .windows(2)
        .filter_map(|w| {
            match (w[0].time_secs, w[1].time_secs) {
                (Some(t0), Some(t1)) => {
                    let gap = (t1 - t0).max(0);
                    // Only count segments shorter than the pause threshold
                    if gap < PAUSE_THRESHOLD_SECS {
                        Some(gap)
                    } else {
                        None
                    }
                }
                _ => None,
            }
        })
        .sum();

    (started_at, duration_s)
}

fn compute_elevation_gain(points: &[TrackPoint]) -> Option<f64> {
    let elevations: Vec<f64> = points.iter().filter_map(|p| p.ele).collect();
    if elevations.len() < 2 {
        return None;
    }
    let gain: f64 = elevations
        .windows(2)
        .filter_map(|w| {
            let d = w[1] - w[0];
            if d > 0.0 { Some(d) } else { None }
        })
        .sum();
    Some(gain)
}

fn parse_gpx(data: &[u8]) -> anyhow::Result<ParsedRun> {
    anyhow::ensure!(
        !data.is_empty() && !data.iter().all(|b| b.is_ascii_whitespace() || *b == 0),
        "GPX file is empty"
    );
    let text = std::str::from_utf8(data)?;
    let doc = roxmltree::Document::parse(text)?;

    let activity_type = doc
        .descendants()
        .find(|n| n.tag_name().name() == "trk")
        .and_then(|trk| trk.children().find(|n| n.tag_name().name() == "type"))
        .and_then(|n| n.text())
        .map(|t| t.trim().to_lowercase());

    let points = doc
        .descendants()
        .filter(|n| n.tag_name().name() == "trkpt")
        .map(parse_trkpt)
        .collect::<anyhow::Result<Vec<_>>>()?;

    anyhow::ensure!(!points.is_empty(), "GPX contains no track points");

    let (started_at, duration_s) = compute_timing(&points);
    let distance_m: f64 = points
        .windows(2)
        .map(|w| haversine_m(w[0].lat, w[0].lon, w[1].lat, w[1].lon))
        .sum();
    let elevation_gain_m = compute_elevation_gain(&points);
    let stats = compute_run_stats(&points);

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
                cad: p.cad.filter(|&c| c > 0),
            })
            .collect()
    };

    let calories = estimate_calories(distance_m, duration_s, stats.avg_hr);

    Ok(ParsedRun {
        started_at,
        duration_s,
        distance_m,
        elevation_gain_m,
        avg_hr: stats.avg_hr,
        max_hr: stats.max_hr,
        avg_cadence: stats.avg_cadence,
        avg_stride_m: stats.avg_stride_m,
        route,
        activity_type,
        weather_temp_c: None,
        weather_wind_kph: None,
        weather_precip_mm: None,
        weather_code: None,
        calories,
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

    let bytes =
        gpx_bytes.ok_or_else(|| (StatusCode::BAD_REQUEST, "Missing `file` field".to_string()))?;

    let mut parsed =
        parse_gpx(&bytes).map_err(|e| (StatusCode::UNPROCESSABLE_ENTITY, e.to_string()))?;

    if !is_running_activity(parsed.activity_type.as_deref()) {
        return Err((
            StatusCode::UNPROCESSABLE_ENTITY,
            format!(
                "Activity type '{}' is not a running activity",
                parsed.activity_type.as_deref().unwrap_or("unknown")
            ),
        )
            .into());
    }

    // Fetch weather for the first route point
    if let Some(first) = parsed.route.first()
        && let Ok(ts) = parse_timestamp(&parsed.started_at)
        && let Some(w) = crate::weather::fetch_weather(&state.http, first.lat, first.lon, ts).await
    {
        parsed.weather_temp_c = Some(w.temp_c);
        parsed.weather_wind_kph = Some(w.wind_kph);
        parsed.weather_precip_mm = Some(w.precip_mm);
        parsed.weather_code = Some(w.code);
    }

    let route_json = serde_json::to_string(&parsed.route).map_err(anyhow::Error::from)?;

    let run = sqlx::query_as::<_, RunSummary>(
        "INSERT INTO runs \
         (started_at, duration_s, distance_m, elevation_gain_m, avg_hr, max_hr, route_json, avg_cadence, avg_stride_m, \
          weather_temp_c, weather_wind_kph, weather_precip_mm, weather_code, calories) \
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) \
         RETURNING id, started_at, duration_s, distance_m, elevation_gain_m, avg_hr, max_hr, notes, is_invalid, \
                   avg_cadence, avg_stride_m, weather_temp_c, weather_wind_kph, weather_precip_mm, weather_code, calories",
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
    .bind(parsed.calories)
    .fetch_one(&state.pool)
    .await?;

    Ok((StatusCode::CREATED, Json(run)))
}

/// # Errors
/// Returns an error if the database query fails.
pub async fn list_runs(
    State(state): State<AppState>,
    Query(pagination): Query<Pagination>,
) -> AppResult<Json<Vec<RunSummary>>> {
    let runs = sqlx::query_as::<_, RunSummary>(
        "SELECT id, started_at, duration_s, distance_m, elevation_gain_m, avg_hr, max_hr, notes, is_invalid, \
                avg_cadence, avg_stride_m, weather_temp_c, weather_wind_kph, weather_precip_mm, weather_code, calories \
         FROM runs ORDER BY started_at DESC LIMIT ? OFFSET ?",
    )
    .bind(pagination.limit)
    .bind(pagination.offset)
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
        calories: Option<i64>,
    }

    let row = sqlx::query_as::<_, RunRow>(
        "SELECT id, started_at, duration_s, distance_m, elevation_gain_m, \
                avg_hr, max_hr, notes, route_json, \
                weather_temp_c, weather_wind_kph, weather_precip_mm, weather_code, calories \
         FROM runs WHERE id = ?",
    )
    .bind(id)
    .fetch_optional(&state.pool)
    .await?
    .ok_or(StatusCode::NOT_FOUND)?;

    let route: Vec<RoutePoint> = serde_json::from_str(&row.route_json).unwrap_or_else(|e| {
        tracing::warn!(run_id = id, error = %e, "Failed to parse route JSON, returning empty route");
        Vec::new()
    });

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
        calories: row.calories,
    }))
}

/// Deletes a run and blocks its source file from future imports.
///
/// # Errors
/// Returns `NOT_FOUND` if the run doesn't exist.
pub async fn delete_run(
    State(state): State<AppState>,
    Path(id): Path<i64>,
) -> AppResult<StatusCode> {
    // Get source_file before deleting so we can block it
    let source_file: Option<String> =
        sqlx::query_scalar("SELECT source_file FROM runs WHERE id = ?")
            .bind(id)
            .fetch_optional(&state.pool)
            .await?
            .ok_or(StatusCode::NOT_FOUND)?;

    // Block this file from future imports
    if let Some(src) = source_file {
        sqlx::query("INSERT OR IGNORE INTO blocked_runs (source_file) VALUES (?)")
            .bind(&src)
            .execute(&state.pool)
            .await?;
    }

    // Delete the run
    sqlx::query("DELETE FROM runs WHERE id = ?")
        .bind(id)
        .execute(&state.pool)
        .await?;

    Ok(StatusCode::NO_CONTENT)
}

/// Delete **all** runs so they can be reimported from scratch.
///
/// # Errors
/// Returns a database error if the deletion fails.
pub async fn delete_all_runs(State(state): State<AppState>) -> AppResult<StatusCode> {
    sqlx::query("DELETE FROM runs").execute(&state.pool).await?;
    Ok(StatusCode::NO_CONTENT)
}

#[derive(Serialize)]
pub(crate) struct ParsedRawDetailsRun {
    /// Workout start from the TIMESTAMP TLV ("local-as-UTC" seconds).
    pub(crate) start_epoch: Option<i64>,
    pub(crate) distance_m: f64,
    pub(crate) elevation_gain_m: Option<f64>,
    pub(crate) avg_hr: Option<i64>,
    pub(crate) max_hr: Option<i64>,
    pub(crate) avg_cadence: Option<i64>,
    pub(crate) avg_stride_m: Option<f64>,
    pub(crate) route: Vec<RoutePoint>,
}

/// Estimate calories for a run: HR-based (Keytel formula scaled to match
/// Gadgetbridge) when avg HR is available, otherwise ~60 kcal per km.
#[allow(
    clippy::cast_possible_truncation,
    clippy::cast_sign_loss,
    clippy::cast_precision_loss
)]
pub(crate) fn estimate_calories(
    distance_m: f64,
    duration_s: i64,
    avg_hr: Option<i64>,
) -> Option<i64> {
    if distance_m <= 0.0 {
        return None;
    }
    let dist_km = distance_m / 1000.0;
    let estimated = avg_hr.map_or(dist_km * 60.0, |hr| {
        // HR-based estimate scaled to match Gadgetbridge (~0.8x Keytel formula)
        // Assumes 70kg, 35 years old
        let duration_min = duration_s as f64 / 60.0;
        let hr_f = hr as f64;
        let base = 0.6309f64.mul_add(
            hr_f,
            0.1988f64.mul_add(70.0, 0.2017f64.mul_add(35.0, -55.0969)),
        );
        (duration_min * base / 4.184 * 0.8).max(0.0)
    });
    Some(estimated.round() as i64)
}

#[allow(clippy::too_many_lines)]
pub(crate) fn parse_zeppos_raw_details_bin(data: &[u8]) -> Option<ParsedRawDetailsRun> {
    #[derive(Clone)]
    struct RawPoint {
        at_ms: i64,
        lat: f64,
        lon: f64,
        ele: Option<f64>,
        hr: Option<i64>,
    }

    fn huami_to_deg(v: i32) -> f64 {
        // Same conversion used in Gadgetbridge's AbstractHuamiActivityDetailsParser.
        f64::from(v) / 3_000_000.0
    }

    fn push_raw_point(
        points: &mut Vec<RawPoint>,
        at_ms: i64,
        lon_raw: i64,
        lat_raw: i64,
        ele: Option<f64>,
    ) {
        let p = RawPoint {
            at_ms,
            lat: huami_to_deg(i32::try_from(lat_raw).unwrap_or_default()),
            lon: huami_to_deg(i32::try_from(lon_raw).unwrap_or_default()),
            ele,
            hr: None,
        };
        if let Some(prev) = points.last()
            && (prev.lat - p.lat).abs() < f64::EPSILON
            && (prev.lon - p.lon).abs() < f64::EPSILON
            && prev.ele == p.ele
        {
            return;
        }
        points.push(p);
    }

    let mut points: Vec<RawPoint> = Vec::new();
    let mut idx = 0usize;

    let mut timestamp_ms = 0i64;
    let mut offset_ms = 0i64;
    let mut longitude = 0i64;
    let mut latitude = 0i64;
    let mut altitude: Option<f64> = None;

    let mut cadence_values: Vec<i64> = Vec::new();
    let mut stride_cm_values: Vec<f64> = Vec::new();

    while idx + 2 <= data.len() {
        let type_code = data[idx];
        let len = usize::from(data[idx + 1]);
        idx += 2;
        if idx + len > data.len() {
            break;
        }
        let slice = &data[idx..idx + len];
        idx += len;

        match (type_code, len) {
            (1, 12) => {
                let ts = i64::from_le_bytes([
                    slice[4], slice[5], slice[6], slice[7], slice[8], slice[9], slice[10],
                    slice[11],
                ]);
                timestamp_ms = ts;
                offset_ms = 0;
            }
            (2, 20) => {
                longitude = i64::from(i32::from_le_bytes([slice[6], slice[7], slice[8], slice[9]]));
                latitude = i64::from(i32::from_le_bytes([
                    slice[10], slice[11], slice[12], slice[13],
                ]));
                push_raw_point(
                    &mut points,
                    timestamp_ms + offset_ms,
                    longitude,
                    latitude,
                    altitude,
                );
            }
            (3, 8) => {
                offset_ms = i64::from(i16::from_le_bytes([slice[0], slice[1]]));
                let dlon = i64::from(i16::from_le_bytes([slice[2], slice[3]]));
                let dlat = i64::from(i16::from_le_bytes([slice[4], slice[5]]));
                longitude += dlon;
                latitude += dlat;
                if !points.is_empty() {
                    push_raw_point(
                        &mut points,
                        timestamp_ms + offset_ms,
                        longitude,
                        latitude,
                        altitude,
                    );
                }
            }
            (4, 4) => {
                offset_ms = i64::from(i16::from_le_bytes([slice[0], slice[1]]));
            }
            (5, 8) => {
                offset_ms = i64::from(i16::from_le_bytes([slice[0], slice[1]]));
                let cadence = i64::from(i16::from_le_bytes([slice[2], slice[3]]));
                let stride_cm = f64::from(i16::from_le_bytes([slice[4], slice[5]]));
                if cadence > 0 {
                    cadence_values.push(cadence);
                }
                if stride_cm > 0.0 {
                    stride_cm_values.push(stride_cm);
                }
            }
            (7, 6) => {
                offset_ms = i64::from(i16::from_le_bytes([slice[0], slice[1]]));
                altitude = Some(
                    f64::from(i32::from_le_bytes([slice[2], slice[3], slice[4], slice[5]])) / 100.0,
                );
                if let Some(last) = points.last_mut() {
                    last.ele = altitude;
                }
            }
            (8, 3) => {
                offset_ms = i64::from(i16::from_le_bytes([slice[0], slice[1]]));
                let hr = i64::from(slice[2]);
                if let Some(last) = points.last_mut() {
                    last.hr = Some(hr);
                }
            }
            _ => {}
        }
    }

    if points.len() < 2 {
        return None;
    }

    let distance_m: f64 = points
        .windows(2)
        .map(|w| haversine_m(w[0].lat, w[0].lon, w[1].lat, w[1].lon))
        .sum();

    let elevation_gain_m = {
        let elevations: Vec<f64> = points.iter().filter_map(|p| p.ele).collect();
        if elevations.len() < 2 {
            None
        } else {
            Some(
                elevations
                    .windows(2)
                    .filter_map(|w| {
                        let d = w[1] - w[0];
                        if d > 0.0 { Some(d) } else { None }
                    })
                    .sum(),
            )
        }
    };

    let hr_values: Vec<i64> = points.iter().filter_map(|p| p.hr).collect();
    let avg_hr = if hr_values.is_empty() {
        None
    } else {
        Some(hr_values.iter().sum::<i64>() / i64::try_from(hr_values.len()).unwrap_or(1))
    };
    let max_hr = hr_values.into_iter().max();

    let t0 = points.first().map_or(0, |p| p.at_ms);
    let route = points
        .into_iter()
        .map(|p| RoutePoint {
            lat: p.lat,
            lon: p.lon,
            ele: p.ele,
            hr: p.hr,
            t: Some((p.at_ms - t0) / 1000),
            cad: None,
        })
        .collect();

    let avg_cadence = if cadence_values.is_empty() {
        None
    } else {
        #[allow(clippy::cast_possible_truncation)]
        Some(cadence_values.iter().sum::<i64>() / i64::try_from(cadence_values.len()).unwrap_or(1))
    };
    let avg_stride_m = if stride_cm_values.is_empty() {
        None
    } else {
        #[allow(clippy::cast_precision_loss)]
        Some(stride_cm_values.iter().sum::<f64>() / stride_cm_values.len() as f64 / 100.0)
    };

    Some(ParsedRawDetailsRun {
        start_epoch: (timestamp_ms > 0).then(|| timestamp_ms.div_euclid(1000)),
        avg_cadence,
        avg_stride_m,
        distance_m,
        elevation_gain_m,
        avg_hr,
        max_hr,
        route,
    })
}

// ── Heatmap ───────────────────────────────────────────────────────────────────

/// Returns all valid run routes as arrays of `[lat, lon]` pairs for map overlay.
///
/// # Errors
/// Returns an error if the database query fails.
pub async fn heatmap(State(state): State<AppState>) -> AppResult<Json<Vec<Vec<[f64; 2]>>>> {
    #[derive(sqlx::FromRow)]
    struct Row {
        route_json: String,
    }

    #[derive(serde::Deserialize)]
    struct Pt {
        lat: f64,
        lon: f64,
    }

    let rows: Vec<Row> =
        sqlx::query_as("SELECT route_json FROM runs WHERE is_invalid = 0 AND route_json != '[]'")
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
                let pace_a = f64::from(i32::try_from(a.duration_s).unwrap_or(i32::MAX)) * target_m
                    / a.distance_m;
                let pace_b = f64::from(i32::try_from(b.duration_s).unwrap_or(i32::MAX)) * target_m
                    / b.distance_m;
                pace_a
                    .partial_cmp(&pace_b)
                    .unwrap_or(std::cmp::Ordering::Equal)
            });
        if let Some(run) = best {
            prs.push(PersonalRecord {
                distance_label: (*label).to_string(),
                run_id: run.id,
                run_date: run.started_at.clone(),
                estimated_seconds: f64::from(i32::try_from(run.duration_s).unwrap_or(i32::MAX))
                    * target_m
                    / run.distance_m,
            });
        }
    }

    Ok(Json(prs))
}

#[derive(Deserialize)]
pub struct SetInvalidBody {
    pub is_invalid: bool,
}

/// Toggle the `is_invalid` flag on a run.
/// When marking as invalid, also adds the source file to `blocked_runs` so it won't be
/// re-imported even after a reset. When unmarking, removes from `blocked_runs`.
///
/// # Errors
/// Returns `NOT_FOUND` if the run doesn't exist, or a database error.
pub async fn set_invalid(
    State(state): State<AppState>,
    Path(id): Path<i64>,
    Json(body): Json<SetInvalidBody>,
) -> AppResult<StatusCode> {
    // Get the source_file for this run
    let source_file: Option<String> =
        sqlx::query_scalar("SELECT source_file FROM runs WHERE id = ?")
            .bind(id)
            .fetch_optional(&state.pool)
            .await?
            .ok_or(StatusCode::NOT_FOUND)?;

    // Update the is_invalid flag
    sqlx::query("UPDATE runs SET is_invalid = ? WHERE id = ?")
        .bind(body.is_invalid)
        .bind(id)
        .execute(&state.pool)
        .await?;

    // Add or remove from blocked_runs based on is_invalid
    if let Some(src) = source_file {
        if body.is_invalid {
            // Block this file from future imports
            sqlx::query("INSERT OR IGNORE INTO blocked_runs (source_file) VALUES (?)")
                .bind(&src)
                .execute(&state.pool)
                .await?;
        } else {
            // Unblock this file
            sqlx::query("DELETE FROM blocked_runs WHERE source_file = ?")
                .bind(&src)
                .execute(&state.pool)
                .await?;
        }
    }

    Ok(StatusCode::NO_CONTENT)
}
