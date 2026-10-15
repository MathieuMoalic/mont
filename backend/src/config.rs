use clap::{ArgAction, Parser, Subcommand};
use std::{net::SocketAddr, path::PathBuf};

#[derive(Parser, Debug)]
#[command(name = "mont", version, about = "HTTP API server for Mont")]
pub struct Cli {
    #[command(subcommand)]
    pub command: Option<Commands>,

    #[command(flatten)]
    pub config: Config,
}

#[derive(Subcommand, Debug, Clone, Copy)]
pub enum Commands {
    /// Generate an Argon2 password hash for authentication
    HashPassword,
}

#[derive(Parser, Debug, Clone)]
pub struct Config {
    #[arg(short = 'v', action = ArgAction::Count, global = true)]
    pub verbose: u8,

    #[arg(short = 'q', action = ArgAction::Count, global = true)]
    pub quiet: u8,

    #[arg(long, env = "MONT_BIND_ADDR", default_value = "0.0.0.0:8080")]
    pub bind: SocketAddr,

    #[arg(long, env = "MONT_DATABASE_PATH", default_value = "mont.sqlite")]
    pub database_path: String,

    #[arg(long, env = "MONT_LOG_FILE", default_value = "mont.log")]
    pub log_file: PathBuf,

    #[arg(long, env = "MONT_CORS_ORIGIN")]
    pub cors_origin: Option<String>,

    #[arg(long, env = "MONT_JWT_SECRET")]
    pub jwt_secret: Option<String>,

    #[arg(long, env = "MONT_PASSWORD_HASH")]
    pub password_hash: Option<String>,

    #[arg(long, env = "MONT_USDA_API_KEY")]
    pub usda_api_key: Option<String>,

    #[arg(
        long,
        env = "MONT_LLM_API_URL",
        default_value = "https://openrouter.ai/api/v"
    )]
    pub llm_api_url: String,

    #[arg(long, env = "MONT_LLM_API_KEY")]
    pub llm_api_key: Option<String>,

    #[arg(
        long,
        env = "MONT_LLM_MODEL",
        default_value = "deepseek/deepseek-v4-flash"
    )]
    pub llm_model: String,

    /// Enable the BLE watch-sync relay endpoint (/ble/ws).
    #[arg(long, env = "MONT_BLE_ENABLED", default_value_t = false)]
    pub ble_enabled: bool,

    /// Device-name filter the BLE relay autopilot matches against scan results.
    #[arg(long, env = "MONT_BLE_WATCH_NAME", default_value = "Amazfit Cheetah")]
    pub ble_watch_name: String,

    /// Watch MAC to connect to directly, skipping the scan (useful for bonded
    /// watches that are not currently advertising).
    #[arg(long, env = "MONT_BLE_WATCH_MAC")]
    pub ble_watch_mac: Option<String>,

    /// Watch auth key: 32 hex chars (optionally `0x`-prefixed), as configured
    /// in Gadgetbridge. Enables the legacy auth handshake after connecting.
    #[arg(long, env = "MONT_BLE_AUTH_KEY")]
    pub ble_auth_key: Option<String>,

    /// How long to observe the watch after the session milestone, in seconds.
    #[arg(long, env = "MONT_BLE_SETTLE_SECS", default_value_t = 30)]
    pub ble_settle_secs: u64,

    /// Run health fetches (activity, resting/max HR, HRV) after authentication.
    #[arg(long, env = "MONT_BLE_FETCH_ENABLED", default_value_t = true)]
    pub ble_fetch_enabled: bool,

    /// How far back to fetch health data on first sync, in days.
    #[arg(long, env = "MONT_BLE_FETCH_LOOKBACK_DAYS", default_value_t = 30)]
    pub ble_fetch_lookback_days: i64,

    /// Directory for BLE session NDJSON recordings (defaults to `<db dir>/ble_sessions`).
    #[arg(long, env = "MONT_BLE_SESSIONS_DIR")]
    pub ble_sessions_dir: Option<PathBuf>,

    /// Maximum duration of a BLE relay session in seconds.
    #[arg(long, env = "MONT_BLE_SESSION_TIMEOUT_SECS", default_value_t = 300)]
    pub ble_session_timeout_secs: u64,
}

impl Config {
    /// Parse the configured auth key into 16 bytes (`None` if unset or invalid).
    #[must_use]
    pub fn ble_auth_key_bytes(&self) -> Option<[u8; 16]> {
        let hex = self
            .ble_auth_key
            .as_deref()
            .map(str::trim)
            .filter(|s| !s.is_empty())?;
        let hex = hex.strip_prefix("0x").unwrap_or(hex);
        if hex.len() != 32 || !hex.chars().all(|c| c.is_ascii_hexdigit()) {
            return None;
        }
        let mut key = [0u8; 16];
        for (i, byte) in key.iter_mut().enumerate() {
            *byte = u8::from_str_radix(&hex[i * 2..i * 2 + 2], 16).ok()?;
        }
        Some(key)
    }

    #[must_use]
    pub fn ble_sessions_dir(&self) -> PathBuf {
        self.ble_sessions_dir.clone().unwrap_or_else(|| {
            PathBuf::from(&self.database_path)
                .parent()
                .map(std::path::Path::to_path_buf)
                .unwrap_or_default()
                .join("ble_sessions")
        })
    }

    #[must_use]
    pub fn verbosity_delta(&self) -> i16 {
        i16::from(self.verbose) - i16::from(self.quiet)
    }

    #[must_use]
    pub fn log_filter(&self) -> &'static str {
        match self.verbosity_delta() {
            d if d <= -2 => "error",
            -1 => "warn",
            0 => "info,mont=info,axum=info,tower_http=info",
            1 => "debug,mont=debug,axum=info,tower_http=info,sqlx=warn",
            _ => "trace,mont=trace,axum=trace,tower_http=trace,sqlx=debug",
        }
    }
}
