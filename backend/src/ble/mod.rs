//! BLE watch-sync relay: WS protocol, session recorder, and session driver.
//!
//! The Flutter app is a dumb GATT relay (scan/connect/subscribe/write, notify
//! events); this module owns all session logic and records every frame to an
//! NDJSON file so sessions can be replayed and analyzed offline.

pub mod auth;
pub mod codec;
pub mod controls;
pub mod driver;
pub mod ecdh_b163;
pub mod fetch;
pub mod file_transfer;
pub mod gpx_route;
pub mod parsers;
pub mod protocol;
pub mod recorder;
pub mod store;
pub mod workout;
