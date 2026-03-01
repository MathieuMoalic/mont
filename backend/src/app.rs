use crate::routes::auth;
use crate::{
    auth_middleware::require_auth,
    config::Config,
    embedded_web::serve_embedded_web,
    logging::{access_log, log_payloads},
    models::AppState,
};

use axum::middleware::{from_fn, from_fn_with_state};
use axum::routing::{get, post};
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

    // Protected routes — add feature routes here as the app grows
    let protected_routes = Router::new()
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
