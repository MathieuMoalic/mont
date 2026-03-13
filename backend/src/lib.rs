#![deny(
    warnings,
    clippy::all,
    clippy::pedantic,
    clippy::nursery,
    clippy::cargo
)]
#![allow(clippy::multiple_crate_versions)]

pub mod app;
pub mod auth_middleware;
pub mod config;
pub mod db;
pub mod embedded_web;
pub mod error;
pub mod logging;
pub mod models;
pub mod routes;
pub mod weather;
