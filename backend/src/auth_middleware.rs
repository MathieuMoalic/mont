use axum::{
    body::Body,
    extract::State,
    http::{Request, StatusCode},
    middleware::Next,
    response::Response,
};
use jsonwebtoken::{Algorithm, DecodingKey, Validation, decode};

use crate::models::AppState;
use crate::routes::auth::{Claims, TokenType};

/// Verify a JWT access token and return its claims.
///
/// # Errors
/// Returns `UNAUTHORIZED` if the token is invalid or is a refresh token,
/// `INTERNAL_SERVER_ERROR` if the JWT secret is not configured.
pub fn verify_access_token(state: &AppState, token: &str) -> Result<Claims, StatusCode> {
    let jwt_secret = state
        .config
        .jwt_secret
        .as_ref()
        .ok_or(StatusCode::INTERNAL_SERVER_ERROR)?;
    let decoding_key = DecodingKey::from_secret(jwt_secret.as_bytes());

    let claims = decode::<Claims>(token, &decoding_key, &Validation::new(Algorithm::HS256))
        .map_err(|_| StatusCode::UNAUTHORIZED)?
        .claims;

    // Only accept access tokens, not refresh tokens
    if claims.token_type != TokenType::Access {
        return Err(StatusCode::UNAUTHORIZED);
    }

    Ok(claims)
}

/// # Errors
/// Returns `UNAUTHORIZED` if the token is missing or invalid, `INTERNAL_SERVER_ERROR` if the JWT secret is not configured.
pub async fn require_auth(
    State(state): State<AppState>,
    request: Request<Body>,
    next: Next,
) -> Result<Response, StatusCode> {
    // Extract token from Authorization header
    let auth_header = request
        .headers()
        .get("authorization")
        .and_then(|v| v.to_str().ok())
        .ok_or(StatusCode::UNAUTHORIZED)?;

    let token = auth_header
        .strip_prefix("Bearer ")
        .ok_or(StatusCode::UNAUTHORIZED)?;

    verify_access_token(&state, token)?;

    Ok(next.run(request).await)
}
