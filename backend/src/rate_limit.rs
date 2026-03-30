use axum::{
    body::Body,
    http::{Request, StatusCode},
    response::{IntoResponse, Response},
};
use std::{
    collections::HashMap,
    sync::{Arc, Mutex, PoisonError},
    time::{Duration, Instant},
};

#[derive(Clone)]
pub struct RateLimiter {
    requests: Arc<Mutex<HashMap<String, Vec<Instant>>>>,
    max_requests: usize,
    window: Duration,
}

impl RateLimiter {
    #[must_use]
    pub fn new(max_requests: usize, window_secs: u64) -> Self {
        Self {
            requests: Arc::new(Mutex::new(HashMap::new())),
            max_requests,
            window: Duration::from_secs(window_secs),
        }
    }

    #[must_use]
    #[allow(clippy::significant_drop_tightening)]
    pub fn check(&self, key: &str) -> bool {
        let now = Instant::now();
        let cutoff = now.checked_sub(self.window).unwrap_or(now);

        let mut requests = self
            .requests
            .lock()
            .unwrap_or_else(PoisonError::into_inner);

        let entry = requests.entry(key.to_string()).or_default();
        entry.retain(|&t| t > cutoff);

        if entry.len() >= self.max_requests {
            return false;
        }

        entry.push(now);
        true
    }
}

#[derive(Clone)]
pub struct RateLimitState {
    pub general: RateLimiter,
    pub login: RateLimiter,
}

impl RateLimitState {
    #[must_use]
    pub fn new() -> Self {
        Self {
            general: RateLimiter::new(100, 60), // 100 requests per minute
            login: RateLimiter::new(5, 60),     // 5 login attempts per minute
        }
    }
}

impl Default for RateLimitState {
    fn default() -> Self {
        Self::new()
    }
}

fn get_client_ip(request: &Request<Body>) -> String {
    // Check X-Forwarded-For header first (for reverse proxy setups)
    if let Some(forwarded) = request.headers().get("x-forwarded-for")
        && let Ok(value) = forwarded.to_str()
        && let Some(ip) = value.split(',').next()
    {
        return ip.trim().to_string();
    }

    // Check X-Real-IP header
    if let Some(real_ip) = request.headers().get("x-real-ip")
        && let Ok(value) = real_ip.to_str()
    {
        return value.trim().to_string();
    }

    // Fallback to a default key (all requests share the same limit)
    "unknown".to_string()
}

pub async fn rate_limit_middleware(
    axum::extract::State(rate_limit): axum::extract::State<RateLimitState>,
    request: Request<Body>,
    next: axum::middleware::Next,
) -> Response {
    let ip = get_client_ip(&request);
    let path = request.uri().path();

    let allowed = if path == "/auth/login" {
        rate_limit.login.check(&ip)
    } else {
        rate_limit.general.check(&ip)
    };

    if !allowed {
        return (
            StatusCode::TOO_MANY_REQUESTS,
            "Rate limit exceeded. Please try again later.",
        )
            .into_response();
    }

    next.run(request).await
}
