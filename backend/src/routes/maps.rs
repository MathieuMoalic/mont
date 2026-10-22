//! Handlers for watch map-tile builds (`/maps/*`).

use axum::Json;
use axum::extract::multipart::Field;
use axum::extract::{Multipart, Path, State};
use axum::http::{StatusCode, header};
use axum::response::Response;
use serde::Serialize;

use crate::error::{AppError, AppResult};
use crate::maps::jobs::{DownloadError, JobSnapshot, MapJobParams};
use crate::maps::{DEFAULT_STYLE, STYLES};
use crate::models::AppState;

#[derive(Serialize)]
pub struct ReadyResponse {
    ready: bool,
}

#[derive(Serialize)]
pub struct JobIdResponse {
    job_id: String,
}

/// Multipart form fields of `POST /maps/jobs`.
struct JobForm {
    gpx_bytes: Vec<u8>,
    style: String,
    buffer_km: f64,
    overlap_degrees: f64,
    refresh_osm: bool,
}

fn server_ready(state: &AppState) -> bool {
    state
        .config
        .mkgmap_jar
        .as_ref()
        .is_some_and(|jar| jar.exists())
        && which::which("java").is_ok()
        && which::which("osmium").is_ok()
}

/// `GET /maps/ready` — whether the server can build map tiles.
pub async fn ready(State(state): State<AppState>) -> Json<ReadyResponse> {
    Json(ReadyResponse {
        ready: server_ready(&state),
    })
}

/// `POST /maps/jobs` — queue a tile build for an uploaded GPX.
///
/// # Errors
/// `BAD_REQUEST` when the server is not configured for map builds, a field
/// is malformed, or the style is unknown; `UNPROCESSABLE_ENTITY` when the
/// GPX cannot be parsed or produces no tiles.
pub async fn create_job(
    State(state): State<AppState>,
    multipart: Multipart,
) -> AppResult<(StatusCode, Json<JobIdResponse>)> {
    let Some(jar) = state.config.mkgmap_jar.clone() else {
        return Err(bad_request("Server is missing MONT_MKGMAP_JAR"));
    };

    let form = read_job_form(multipart).await?;
    // Parse and compute tiles up front so bad GPX input fails fast with 422
    // instead of failing inside the background job.
    let points = crate::maps::geometry::gpx_points(&form.gpx_bytes)
        .map_err(|e| (StatusCode::UNPROCESSABLE_ENTITY, e.to_string()))?;
    crate::maps::geometry::required_tiles_and_bounds(&points, form.buffer_km, form.overlap_degrees)
        .map_err(|e| (StatusCode::UNPROCESSABLE_ENTITY, e.to_string()))?;

    if !jar.exists() {
        return Err(bad_request(format!(
            "Missing mkgmap jar: {}",
            jar.display()
        )));
    }

    let job_id = uuid::Uuid::new_v4().to_string();
    let temp_dir = std::env::temp_dir().join(format!("mont-maps-{job_id}"));
    tokio::fs::create_dir_all(&temp_dir)
        .await
        .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?;
    tokio::fs::write(temp_dir.join("upload.gpx"), &form.gpx_bytes)
        .await
        .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?;

    state.maps_jobs.insert(job_id.clone(), temp_dir.clone());
    crate::maps::jobs::spawn(
        state,
        job_id.clone(),
        temp_dir,
        MapJobParams {
            style: form.style,
            buffer_km: form.buffer_km,
            overlap_degrees: form.overlap_degrees,
            refresh_osm: form.refresh_osm,
        },
    );
    Ok((StatusCode::OK, Json(JobIdResponse { job_id })))
}

async fn read_job_form(mut multipart: Multipart) -> AppResult<JobForm> {
    let mut gpx_bytes: Option<Vec<u8>> = None;
    let mut style = DEFAULT_STYLE.to_string();
    let mut buffer_km = 1.0_f64;
    let mut overlap_degrees = 0.002_f64;
    let mut refresh_osm = false;

    while let Some(field) = multipart
        .next_field()
        .await
        .map_err(|e| (StatusCode::BAD_REQUEST, e.body_text()))?
    {
        match field.name() {
            Some("file") => {
                gpx_bytes = Some(
                    field
                        .bytes()
                        .await
                        .map_err(|e| (StatusCode::BAD_REQUEST, e.body_text()))?
                        .to_vec(),
                );
            }
            Some("style") => style = text_field(field).await?,
            Some("buffer_km") => buffer_km = number_field(field, "buffer_km").await?,
            Some("overlap_degrees") => {
                overlap_degrees = number_field(field, "overlap_degrees").await?;
            }
            Some("refresh_osm") => {
                refresh_osm = matches!(text_field(field).await?.trim(), "true" | "1" | "on");
            }
            _ => {}
        }
    }

    if !STYLES.contains(&style.as_str()) {
        return Err(bad_request(format!(
            "Unknown style: {style} (available: {})",
            STYLES.join(", ")
        )));
    }
    if buffer_km < 0.0 {
        return Err(bad_request("buffer_km must be >= 0"));
    }
    if overlap_degrees < 0.0 {
        return Err(bad_request("overlap_degrees must be >= 0"));
    }
    let Some(gpx_bytes) = gpx_bytes else {
        return Err(bad_request("Missing `file` field"));
    };
    Ok(JobForm {
        gpx_bytes,
        style,
        buffer_km,
        overlap_degrees,
        refresh_osm,
    })
}

async fn text_field(field: Field<'_>) -> AppResult<String> {
    field
        .text()
        .await
        .map_err(|e| (StatusCode::BAD_REQUEST, e.body_text()).into())
}

async fn number_field(field: Field<'_>, name: &str) -> AppResult<f64> {
    let text = text_field(field).await?;
    text.trim()
        .parse::<f64>()
        .map_err(|_| (StatusCode::BAD_REQUEST, format!("Invalid {name}: {text}")).into())
}

fn bad_request(message: impl Into<String>) -> AppError {
    (StatusCode::BAD_REQUEST, message.into()).into()
}

/// `GET /maps/jobs/{id}` — status, logs and readiness of a job.
///
/// # Errors
/// `NOT_FOUND` when the job id is unknown.
pub async fn job_status(
    State(state): State<AppState>,
    Path(job_id): Path<String>,
) -> AppResult<Json<JobSnapshot>> {
    state
        .maps_jobs
        .snapshot(&job_id)
        .map(Json)
        .ok_or_else(|| (StatusCode::NOT_FOUND, "Unknown job id".to_string()).into())
}

/// `GET /maps/jobs/{id}/download` — the finished ZIP; single-use.
///
/// # Errors
/// `NOT_FOUND` when unknown, `CONFLICT` while running or after a failure.
pub async fn job_download(
    State(state): State<AppState>,
    Path(job_id): Path<String>,
) -> AppResult<Response> {
    let (zip_path, temp_dir) = state
        .maps_jobs
        .take_download(&job_id)
        .map_err(|e| -> AppError {
            match e {
                DownloadError::UnknownJob => {
                    (StatusCode::NOT_FOUND, "Unknown job id".to_string()).into()
                }
                DownloadError::NotFinished => {
                    (StatusCode::CONFLICT, "Job is not finished yet".to_string()).into()
                }
                DownloadError::Failed(detail) => (StatusCode::CONFLICT, detail).into(),
            }
        })?;

    let bytes = tokio::fs::read(&zip_path)
        .await
        .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?;
    let _ = tokio::fs::remove_dir_all(&temp_dir).await;

    Response::builder()
        .status(StatusCode::OK)
        .header(header::CONTENT_TYPE, "application/zip")
        .header(
            header::CONTENT_DISPOSITION,
            "attachment; filename=\"11.zip\"",
        )
        .body(axum::body::Body::from(bytes))
        .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()).into())
}
