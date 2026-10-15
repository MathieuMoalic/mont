//! BLE watch-sync relay: WS protocol, session recorder, and session driver.
//!
//! The Flutter app is a dumb GATT relay (scan/connect/subscribe/write, notify
//! events); this module owns all session logic and records every frame to an
//! NDJSON file so sessions can be replayed and analyzed offline.

pub mod auth;
pub mod codec;
pub mod driver;
pub mod fetch;
pub mod parsers;
pub mod protocol;
pub mod recorder;
pub mod store;
pub mod workout;
