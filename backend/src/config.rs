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

    #[arg(long, env = "MONT_GADGETBRIDGE_PATH")]
    pub gadgetbridge_path: Option<PathBuf>,
}

impl Config {
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
