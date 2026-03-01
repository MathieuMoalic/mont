use axum::{Json, http::StatusCode, response::IntoResponse};
use serde::Serialize;

#[derive(Debug)]
pub enum AppError {
    Status(StatusCode),
    Msg(StatusCode, String),
    Anyhow(anyhow::Error),
}

impl From<StatusCode> for AppError {
    fn from(code: StatusCode) -> Self { Self::Status(code) }
}

impl From<(StatusCode, String)> for AppError {
    fn from((code, msg): (StatusCode, String)) -> Self { Self::Msg(code, msg) }
}

impl From<anyhow::Error> for AppError {
    fn from(e: anyhow::Error) -> Self { Self::Anyhow(e) }
}

impl From<sqlx::Error> for AppError {
    fn from(e: sqlx::Error) -> Self { Self::Anyhow(e.into()) }
}

impl From<std::io::Error> for AppError {
    fn from(e: std::io::Error) -> Self { Self::Anyhow(e.into()) }
}

impl From<axum::extract::rejection::JsonRejection> for AppError {
    fn from(rejection: axum::extract::rejection::JsonRejection) -> Self {
        Self::Msg(StatusCode::UNPROCESSABLE_ENTITY, rejection.body_text())
    }
}

#[derive(Serialize)]
struct ErrBody { error: String }

impl IntoResponse for AppError {
    fn into_response(self) -> axum::response::Response {
        match self {
            Self::Status(code) => code.into_response(),
            Self::Msg(code, msg) => {
                if code.is_client_error() {
                    tracing::debug!("Client error {code}: {msg}");
                } else {
                    tracing::error!("Server error {code}: {msg}");
                }
                (code, msg).into_response()
            }
            Self::Anyhow(err) => {
                tracing::error!("{err:#}");
                (StatusCode::INTERNAL_SERVER_ERROR, Json(ErrBody { error: err.to_string() }))
                    .into_response()
            }
        }
    }
}

pub type AppResult<T> = Result<T, AppError>;
