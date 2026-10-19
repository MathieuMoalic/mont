//! BLE watch-sync endpoints: the relay WebSocket and a status helper.

use std::time::UNIX_EPOCH;

use axum::Json;
use axum::extract::ws::WebSocketUpgrade;
use axum::extract::{Query, State};
use axum::http::{HeaderMap, StatusCode};
use axum::response::{IntoResponse, Response};
use serde::{Deserialize, Serialize};
use serde_json::json;

use crate::auth_middleware::verify_access_token;
use crate::ble::driver;
use crate::models::AppState;

#[derive(Debug, Deserialize)]
pub struct WsQuery {
    pub token: Option<String>,
    /// What triggered the sync (`app_open`, `manual`, `adb`) — recorded in
    /// the sync history.
    pub source: Option<String>,
}

/// Relay WebSocket: `GET /ble/ws?token=<jwt>` (query param because browser
/// WebSocket clients cannot set headers).
///
/// Requires the BLE feature to be enabled (`MONT_BLE_ENABLED=true`).
pub async fn ws_handler(
    State(state): State<AppState>,
    Query(query): Query<WsQuery>,
    headers: HeaderMap,
    ws: WebSocketUpgrade,
) -> Response {
    if !state.config.ble_enabled {
        return (StatusCode::NOT_FOUND, "BLE sync is disabled").into_response();
    }
    let token = query.token.or_else(|| bearer_token(&headers));
    let Some(token) = token else {
        return (StatusCode::UNAUTHORIZED, "missing token").into_response();
    };
    if verify_access_token(&state, &token).is_err() {
        return (StatusCode::UNAUTHORIZED, "invalid token").into_response();
    }
    let source = query
        .source
        .map(|s| {
            s.chars()
                .filter(|c| c.is_ascii_alphanumeric() || *c == '_')
                .take(20)
                .collect::<String>()
        })
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "sync".to_string());
    ws.on_upgrade(move |socket| driver::run_session(socket, state, source))
}

/// `GET /ble/sync-log?limit=` — what recent sync sessions imported, newest
/// first (for the Settings tab).
pub async fn sync_log_handler(
    State(state): State<AppState>,
    Query(query): Query<SyncLogQuery>,
) -> Response {
    if !state.config.ble_enabled {
        return (StatusCode::NOT_FOUND, "BLE sync is disabled").into_response();
    }
    let limit = query.limit.unwrap_or(100).clamp(1, 500);
    match crate::ble::store::load_sync_log(&state.pool, limit).await {
        Ok(entries) => Json(json!({ "entries": entries })).into_response(),
        Err(e) => (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()).into_response(),
    }
}

#[derive(Debug, Deserialize)]
pub struct SyncLogQuery {
    pub limit: Option<i64>,
}

fn bearer_token(headers: &HeaderMap) -> Option<String> {
    let value = headers.get("authorization")?.to_str().ok()?;
    value.strip_prefix("Bearer ").map(str::to_string)
}

#[derive(Serialize)]
struct SessionFileInfo {
    file: String,
    bytes: u64,
    modified_epoch: Option<u64>,
}

#[derive(Serialize)]
struct BleStatus {
    enabled: bool,
    watch_name: String,
    sessions: Vec<SessionFileInfo>,
}

/// `GET /ble/status` — feature flag and recent session recordings.
pub async fn status_handler(State(state): State<AppState>) -> Response {
    let watch_name = state.config.ble_watch_name.clone();
    if !state.config.ble_enabled {
        return Json(BleStatus {
            enabled: false,
            watch_name,
            sessions: Vec::new(),
        })
        .into_response();
    }

    Json(BleStatus {
        enabled: true,
        watch_name,
        sessions: list_sessions(&state.config.ble_sessions_dir()),
    })
    .into_response()
}

fn list_sessions(dir: &std::path::Path) -> Vec<SessionFileInfo> {
    let mut sessions: Vec<SessionFileInfo> = Vec::new();
    if let Ok(entries) = std::fs::read_dir(dir) {
        for entry in entries.flatten() {
            let Ok(meta) = entry.metadata() else {
                continue;
            };
            if !meta.is_file() {
                continue;
            }
            sessions.push(SessionFileInfo {
                file: entry.file_name().to_string_lossy().into_owned(),
                bytes: meta.len(),
                modified_epoch: meta
                    .modified()
                    .ok()
                    .and_then(|m| m.duration_since(UNIX_EPOCH).ok())
                    .map(|d| d.as_secs()),
            });
        }
    }
    sessions.sort_by(|a, b| b.modified_epoch.cmp(&a.modified_epoch));
    sessions.truncate(20);
    sessions
}

// ── Debug data (temporary, for the app's debug tab) ─────────────────────────

#[derive(Serialize)]
struct SyncStateRow {
    data_type: i64,
    #[serde(rename = "lastSyncTs")]
    last_sync_ts: i64,
    #[serde(rename = "lastSyncDate")]
    last_sync_date: Option<String>,
}

#[derive(Serialize)]
struct DebugBlob {
    enabled: bool,
    #[serde(rename = "syncState")]
    sync_state: Vec<SyncStateRow>,
    #[serde(rename = "sampleRange")]
    sample_range: Option<SampleRange>,
    daily: Vec<serde_json::Value>,
    hrv: Vec<serde_json::Value>,
    #[serde(rename = "hrMarks")]
    hr_marks: Vec<serde_json::Value>,
    sessions: Vec<SessionFileInfo>,
}

#[derive(Serialize)]
struct SampleRange {
    samples: i64,
    first: Option<i64>,
    last: Option<i64>,
}

/// `GET /ble/debug` — everything imported over BLE, for the debug tab.
pub async fn debug_handler(State(state): State<AppState>) -> Response {
    if !state.config.ble_enabled {
        return (StatusCode::NOT_FOUND, "BLE sync is disabled").into_response();
    }

    let pool = &state.pool;
    let sync_state: Vec<SyncStateRow> = sqlx::query_as::<_, (i64, i64, Option<String>)>(
        "SELECT data_type, last_sync_ts, date(last_sync_ts, 'unixepoch') FROM watch_sync_state ORDER BY data_type",
    )
    .fetch_all(pool)
    .await
    .unwrap_or_default()
    .into_iter()
    .map(|(data_type, last_sync_ts, last_sync_date)| SyncStateRow {
        data_type,
        last_sync_ts,
        last_sync_date,
    })
    .collect();

    let sample_range = sqlx::query_as::<_, (i64, Option<i64>, Option<i64>)>(
        "SELECT COUNT(*), MIN(ts), MAX(ts) FROM activity_samples",
    )
    .fetch_optional(pool)
    .await
    .ok()
    .flatten()
    .map(|(samples, first, last)| SampleRange {
        samples,
        first,
        last,
    });

    let daily: Vec<serde_json::Value> = sqlx::query_as::<_, (String, Option<i64>, Option<i64>, Option<i64>, Option<i64>, Option<f64>)>(
        "SELECT date, avg_hr, min_hr, max_hr, steps, hrv_rmssd FROM daily_health ORDER BY date DESC LIMIT 14",
    )
    .fetch_all(pool)
    .await
    .unwrap_or_default()
    .into_iter()
    .map(
        |(date, avg_hr, min_hr, max_hr, steps, hrv)| {
            json!({"date": date, "avgHr": avg_hr, "minHr": min_hr, "maxHr": max_hr, "steps": steps, "hrv": hrv})
        },
    )
    .collect();

    let hrv: Vec<serde_json::Value> = sqlx::query_as::<_, (i64, i64)>(
        "SELECT ts, value FROM hrv_samples ORDER BY ts DESC LIMIT 50",
    )
    .fetch_all(pool)
    .await
    .unwrap_or_default()
    .into_iter()
    .map(|(ts, value)| json!({"ts": ts, "value": value}))
    .collect();

    let hr_marks: Vec<serde_json::Value> = sqlx::query_as::<_, (String, Option<i64>, Option<i64>)>(
        "SELECT date, resting_hr, max_hr FROM daily_hr_marks ORDER BY date DESC LIMIT 14",
    )
    .fetch_all(pool)
    .await
    .unwrap_or_default()
    .into_iter()
    .map(|(date, resting, max)| json!({"date": date, "restingHr": resting, "maxHr": max}))
    .collect();

    Json(DebugBlob {
        enabled: true,
        sync_state,
        sample_range,
        daily,
        hrv,
        hr_marks,
        sessions: list_sessions(&state.config.ble_sessions_dir()),
    })
    .into_response()
}
