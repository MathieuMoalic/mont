use crate::routes::{auth, exercises, health, runs, weight, workouts};
use crate::{
    auth_middleware::require_auth,
    config::Config,
    embedded_web::serve_embedded_web,
    logging::{access_log, log_payloads},
    models::AppState,
};

use axum::middleware::{from_fn, from_fn_with_state};
use axum::routing::{delete, get, patch, post};
use axum::{Json, Router};
use serde::Serialize;

use tower_http::cors::{Any, CorsLayer};
use tower_http::request_id::{MakeRequestUuid, PropagateRequestIdLayer, SetRequestIdLayer};
use tower::ServiceBuilder;

async fn healthz() -> Json<&'static str> {
    Json("ok")
}

#[derive(Serialize)]
struct VersionInfo {
    version: &'static str,
}

async fn version() -> Json<VersionInfo> {
    Json(VersionInfo {
        version: env!("CARGO_PKG_VERSION"),
    })
}

fn cors_layer(config: &Config) -> CorsLayer {
    let cors = CorsLayer::new().allow_methods(Any).allow_headers(Any);
    if let Some(origin) = &config.cors_origin {
        cors.allow_origin(
            origin
                .parse::<axum::http::HeaderValue>()
                .expect("Invalid CORS origin"),
        )
    } else {
        tracing::warn!("CORS configured to allow any origin - not secure for production!");
        cors.allow_origin(Any)
    }
}

#[allow(clippy::needless_pass_by_value)]
pub fn build_app(state: AppState) -> Router {
    let request_id_layer = ServiceBuilder::new()
        .layer(SetRequestIdLayer::x_request_id(MakeRequestUuid))
        .layer(PropagateRequestIdLayer::x_request_id());

    let public_routes = Router::new()
        .route("/healthz", get(healthz))
        .route("/version", get(version))
        .route("/auth/login", post(auth::login));

    let protected_routes = Router::new()
        .route("/exercises", get(exercises::list_exercises).post(exercises::create_exercise))
        .route("/exercises/{id}/history", get(exercises::exercise_history))
        .route("/health/daily", get(health::list_daily_health))
        .route("/health/fit", post(health::import_health_fit))
        .route("/health/ble", post(health::import_health_ble))
        .route("/workouts", get(workouts::list_workouts).post(workouts::create_workout))
        .route("/workouts/{id}", get(workouts::get_workout).delete(workouts::delete_workout))
        .route("/workouts/{id}/finish", patch(workouts::finish_workout))
        .route("/workouts/{id}/restart", patch(workouts::restart_workout))
        .route("/workouts/{id}/sets", post(workouts::add_set))
        .route("/workouts/{id}/sets/{set_id}", delete(workouts::delete_set))
        .route("/weight", get(weight::list_weight).post(weight::create_weight_entry))
        .route("/weight/{id}", delete(weight::delete_weight_entry).patch(weight::update_weight_entry))
        .route("/runs", get(runs::list_runs).delete(runs::delete_all_runs))
        .route("/runs/prs", get(runs::personal_records))
        .route("/runs/heatmap", get(runs::heatmap))
        .route("/runs/import", post(runs::import_run))
        .route("/runs/import/fit", post(runs::import_run_fit))
        .route("/runs/ble", post(runs::import_ble_summary))
        .route("/runs/ble-route", patch(runs::patch_ble_route))
        .route("/runs/{id}", get(runs::get_run).delete(runs::delete_run).patch(runs::set_invalid))
        .route_layer(from_fn_with_state(state.clone(), require_auth));

    Router::new()
        .merge(public_routes)
        .merge(protected_routes)
        .fallback(serve_embedded_web)
        .with_state(state.clone())
        .layer(request_id_layer)
        .layer(from_fn(access_log))
        .layer(from_fn(log_payloads))
        .layer(cors_layer(&state.config))
}
