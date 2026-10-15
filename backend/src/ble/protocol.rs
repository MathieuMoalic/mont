//! WS relay message types.
//!
//! Frames are JSON. Backend → client frames are `{"t":"cmd","id":N,"k":…}`
//! envelopes; client → backend frames are `{"t":"evt","k":…}` envelopes.
//! Binary GATT payloads are base64-encoded.

use serde::{Deserialize, Serialize};

mod serde_b64 {
    use base64::Engine as _;
    use serde::{Deserialize, Deserializer, Serializer};

    pub fn serialize<S: Serializer>(v: &[u8], s: S) -> Result<S::Ok, S::Error> {
        s.serialize_str(&base64::engine::general_purpose::STANDARD.encode(v))
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<Vec<u8>, D::Error> {
        let s = String::deserialize(d)?;
        base64::engine::general_purpose::STANDARD
            .decode(s.as_bytes())
            .map_err(serde::de::Error::custom)
    }
}

/// A GATT characteristic as reported by the relay client after discovery.
#[allow(clippy::struct_excessive_bools)] // mirrors GATT characteristic properties
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct CharacteristicInfo {
    pub uuid: String,
    #[serde(default)]
    pub read: bool,
    #[serde(default)]
    pub write: bool,
    #[serde(rename = "write_without_response", default)]
    pub write_without_response: bool,
    #[serde(default)]
    pub notify: bool,
    #[serde(default)]
    pub indicate: bool,
}

/// A GATT service as reported by the relay client after discovery.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ServiceInfo {
    pub uuid: String,
    #[serde(default)]
    pub characteristics: Vec<CharacteristicInfo>,
}

/// A single BLE notification payload.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct NotifyItem {
    pub char_uuid: String,
    #[serde(with = "serde_b64")]
    pub data: Vec<u8>,
}

/// Events sent by the relay client (phone) to the backend.
#[derive(Debug, Clone, Deserialize)]
#[serde(tag = "k", rename_all = "snake_case")]
pub enum RelayEvent {
    /// Session bootstrap; first frame sent by the client after connecting.
    Hello {
        #[serde(default)]
        platform: Option<String>,
        #[serde(default)]
        app_version: Option<String>,
    },
    /// A device seen during scanning.
    ScanResult {
        mac: String,
        #[serde(default)]
        name: Option<String>,
        #[serde(default)]
        rssi: Option<i32>,
    },
    /// The requested device connected (GATT-level).
    Connected {
        #[serde(default)]
        mtu: Option<u16>,
    },
    /// The device disconnected (or the connection attempt failed at GATT level).
    Disconnected {
        #[serde(default)]
        reason: Option<String>,
    },
    /// Negotiated MTU changed.
    Mtu { mtu: u16 },
    /// Result of GATT service discovery.
    Services { services: Vec<ServiceInfo> },
    /// Batched BLE notifications.
    NotifyBatch { items: Vec<NotifyItem> },
    /// Acknowledgement (and result) of a previously sent command.
    CmdResult {
        id: u64,
        ok: bool,
        #[serde(default)]
        error: Option<String>,
    },
    /// Free-form client diagnostic.
    Log { msg: String },
}

/// Commands sent by the backend to the relay client.
#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
#[serde(tag = "k", rename_all = "snake_case")]
pub enum RelayCommand {
    /// Start scanning; results with names containing `name_filter` are relevant.
    ScanStart {
        name_filter: String,
    },
    ScanStop,
    Connect {
        mac: String,
    },
    /// Disconnect the currently connected GATT device (if any).
    DisconnectDevice,
    /// Enable notifications on a characteristic.
    Subscribe {
        char_uuid: String,
    },
    RequestMtu {
        mtu: u16,
    },
    Write {
        char_uuid: String,
        #[serde(with = "serde_b64")]
        data: Vec<u8>,
        without_response: bool,
    },
    /// End the session; the client should clean up and close the socket.
    Shutdown {
        reason: String,
    },
}

/// Envelope for a backend → client command frame.
#[derive(Debug, Clone, Serialize)]
pub struct CommandFrame {
    pub t: &'static str,
    pub id: u64,
    #[serde(flatten)]
    pub command: RelayCommand,
}

/// Envelope for a client → backend event frame.
#[derive(Debug, Clone, Deserialize)]
pub struct EventFrame {
    #[serde(default)]
    pub t: String,
    #[serde(flatten)]
    pub event: RelayEvent,
}

#[must_use]
pub const fn command_frame(id: u64, command: RelayCommand) -> CommandFrame {
    CommandFrame {
        t: "cmd",
        id,
        command,
    }
}
