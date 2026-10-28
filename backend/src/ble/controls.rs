//! Watch Wi-Fi hotspot + FTP server control protocol, ported from
//! Gadgetbridge's `ZeppOsWifiService` (endpoint `0x0003`) and
//! `ZeppOsFtpServerService` (endpoint `0x0006`).
//!
//! The session-key handshake comes from `ZeppOsAuthenticationService`
//! (endpoint `0x0082`).
//!
//! Both control endpoints are encrypted services: frames carry the `0x08`
//! flag and an AES-128-ECB body keyed with `sessionKey ^ handle` (see
//! `codec.rs`). The session key comes from the `ECDH-B163` exchange.

use super::auth::aes_ecb_block;
use super::ecdh_b163;
use super::file_transfer::FILE_TRANSFER_ENDPOINT;

pub const WIFI_ENDPOINT: u16 = 0x0003;
pub const FTP_ENDPOINT: u16 = 0x0006;
pub const AUTH_ENDPOINT: u16 = 0x0082;

/// Third NUL-terminated string in the hotspot-start payload — Gadgetbridge
/// hardcodes its own name; kept identical for watch-side compatibility.
const HOTSPOT_CLIENT_NAME: &str = "gadgetbridge";
/// FTP root used by Gadgetbridge's file-transfer session (`/mnt/data`).
pub const FTP_ROOT_DIR: &str = "/mnt/data";

// ── Actions ──────────────────────────────────────────────────────────────────

/// One user-requested watch control action (from the relay client).
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(tag = "k", rename_all = "snake_case")]
pub enum ControlAction {
    /// Start the Wi-Fi hotspot with the given credentials.
    HotspotStart { ssid: String, password: String },
    /// Stop the Wi-Fi hotspot.
    HotspotStop,
    /// Start the FTP server rooted at `root_dir`.
    FtpStart { root_dir: String },
    /// Stop the FTP server.
    FtpStop,
    /// Send a GPX route file to the watch over the BLE file-transfer
    /// service; it appears in the watch's route/navigation list. `name` is
    /// the track name shown on the watch; `data` is the raw GPX.
    FileSend {
        name: String,
        #[serde(with = "crate::ble::protocol::serde_b64")]
        data: Vec<u8>,
    },
}

impl ControlAction {
    /// The watch endpoint this action speaks on.
    #[must_use]
    pub const fn endpoint(&self) -> u16 {
        match self {
            Self::HotspotStart { .. } | Self::HotspotStop => WIFI_ENDPOINT,
            Self::FtpStart { .. } | Self::FtpStop => FTP_ENDPOINT,
            // Capabilities/request frames; V3 data chunks use char 0x23.
            Self::FileSend { .. } => FILE_TRANSFER_ENDPOINT,
        }
    }

    /// Human-readable name for logs and the sync history.
    #[must_use]
    pub fn name(&self) -> String {
        match self {
            Self::HotspotStart { ssid, .. } => format!("hotspot_start({ssid})"),
            Self::HotspotStop => "hotspot_stop".to_string(),
            Self::FtpStart { root_dir } => format!("ftp_start({root_dir})"),
            Self::FtpStop => "ftp_stop".to_string(),
            Self::FileSend { name, .. } => format!("file_send({name})"),
        }
    }

    /// Build the request payload (`[cmd]` + arguments, NUL-terminated).
    /// Only used for single-frame actions — `FileSend` runs the multi-step
    /// file-transfer protocol instead.
    ///
    /// # Errors
    /// The action arguments are invalid (empty SSID, short password), or
    /// the action is multi-step.
    pub fn payload(&self) -> Result<Vec<u8>, String> {
        match self {
            Self::HotspotStart { ssid, password } => {
                if ssid.is_empty() {
                    return Err("hotspot SSID must not be empty".to_string());
                }
                if password.len() < 8 {
                    return Err("hotspot password must be at least 8 characters".to_string());
                }
                let mut payload = vec![0x11];
                payload.extend_from_slice(ssid.as_bytes());
                payload.push(0);
                payload.extend_from_slice(password.as_bytes());
                payload.push(0);
                payload.extend_from_slice(HOTSPOT_CLIENT_NAME.as_bytes());
                payload.push(0);
                Ok(payload)
            }
            Self::HotspotStop => Ok(vec![0x12]),
            Self::FtpStart { root_dir } => {
                let mut payload = vec![0x01];
                if !root_dir.is_empty() {
                    payload.extend_from_slice(root_dir.as_bytes());
                    payload.push(0);
                }
                Ok(payload)
            }
            Self::FtpStop => Ok(vec![0x02]),
            Self::FileSend { .. } => {
                Err("file transfers use the multi-step file-transfer protocol".to_string())
            }
        }
    }
}

/// Wi-Fi hotspot state from a `0x13` reply (`0x00` stopped, `0x02` started).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HotspotState {
    Stopped,
    Started,
}

/// Parse a `0x0003` reply payload (`13 <state>`).
///
/// # Errors
/// Unexpected payload shape or state byte.
pub fn parse_hotspot_reply(payload: &[u8]) -> Result<HotspotState, String> {
    if payload.first() != Some(&0x13) {
        return Err(format!(
            "unexpected hotspot reply: {:02x?}",
            payload.first()
        ));
    }
    match payload.get(1) {
        Some(0x00) => Ok(HotspotState::Stopped),
        Some(0x02) => Ok(HotspotState::Started),
        other => Err(format!("hotspot error state: {other:02x?}")),
    }
}

/// FTP server state parsed from a `0x0006` reply.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FtpReply {
    /// `0x00` stopped, `0x02` started.
    pub state: u8,
    /// `host:port` of the FTP server (started state only).
    pub address: Option<String>,
    /// Watch-generated FTP username (started state only; empty password).
    pub username: Option<String>,
}

/// Parse a `0x0006` reply payload (`03 <state>[<address>\0][<username>\0]`).
///
/// # Errors
/// Unexpected payload shape.
pub fn parse_ftp_reply(payload: &[u8]) -> Result<FtpReply, String> {
    if payload.first() != Some(&0x03) {
        return Err(format!("unexpected ftp reply: {:02x?}", payload.first()));
    }
    let state = payload.get(1).copied().unwrap_or(0);
    if payload.len() == 2 {
        return Ok(FtpReply {
            state,
            address: None,
            username: None,
        });
    }
    let body = &payload[2..];
    let (address, rest) = split_nul(body).ok_or("ftp reply: unterminated address")?;
    let (username, rest) = split_nul(rest).ok_or("ftp reply: unterminated username")?;
    if !rest.is_empty() {
        return Err("ftp reply: trailing bytes".to_string());
    }
    Ok(FtpReply {
        state,
        address: Some(address),
        username: Some(username),
    })
}

fn split_nul(data: &[u8]) -> Option<(String, &[u8])> {
    let end = data.iter().position(|&b| b == 0)?;
    Some((
        String::from_utf8_lossy(&data[..end]).into_owned(),
        &data[end + 1..],
    ))
}

// ── Session-key handshake (endpoint 0x0082) ─────────────────────────────────

/// Outcome of feeding a `0x0082` payload into [`ControlsAuth::on_payload`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AuthStep {
    /// Send this payload on the chunked write characteristic to continue.
    Reply(Vec<u8>),
    /// Handshake complete; session encryption is now active.
    Authenticated,
    /// The watch rejected the key (status `0x25`).
    Failure(&'static str),
}

/// State machine for the `0x0082` ECDH session-key handshake.
#[derive(Debug)]
pub struct ControlsAuth {
    private_ec: [u8; 24],
    session_key: [u8; 16],
    /// Initial encrypted-sequence number (`LE32(sharedX[0..4])`).
    initial_seq_nr: u32,
}

impl ControlsAuth {
    /// Generate an ephemeral keypair and build the handshake-initiating
    /// payload (`04 02 00 02 ‖ publicEC`).
    ///
    /// # Errors
    /// The ECDH public-key derivation rejected the random private key
    /// (astronomically rare; retry).
    pub fn new() -> Result<(Self, Vec<u8>), String> {
        let mut private_ec = [0u8; 24];
        rand::RngCore::fill_bytes(&mut rand::rngs::OsRng, &mut private_ec);
        let Some(public_ec) = ecdh_b163::generate_public(&private_ec) else {
            return Err("ECDH private key too small, retry".to_string());
        };
        let mut payload = Vec::with_capacity(52);
        payload.extend_from_slice(&[0x04, 0x02, 0x00, 0x02]);
        payload.extend_from_slice(&public_ec);
        let auth = Self {
            private_ec,
            session_key: [0; 16],
            initial_seq_nr: 0,
        };
        Ok((auth, payload))
    }

    /// Feed one reply from the watch.
    ///
    /// On the public-key reply, this derives the session key
    /// (`sharedX[8..24] XOR authKey`), stores it, and returns the
    /// double-encrypted-random confirmation payload.
    ///
    /// # Errors
    /// Malformed payload.
    pub fn on_payload(&mut self, payload: &[u8], auth_key: &[u8; 16]) -> Result<AuthStep, String> {
        if payload.first() != Some(&0x10) {
            return Err(format!("unexpected auth payload: {:02x?}", payload.first()));
        }
        match payload.get(1) {
            Some(0x04) => {
                if payload.get(2) != Some(&0x01) {
                    return Err(format!(
                        "pub key command failure: status {:02x?}",
                        payload.get(2)
                    ));
                }
                if payload.len() < 19 + 48 {
                    return Err("pub key reply too short".to_string());
                }
                let mut remote_random = [0u8; 16];
                remote_random.copy_from_slice(&payload[3..19]);
                let mut remote_public = [0u8; 48];
                remote_public.copy_from_slice(&payload[19..67]);
                let Some(shared) = ecdh_b163::shared_secret(&self.private_ec, &remote_public)
                else {
                    return Err("watch public key is not on the curve".to_string());
                };
                self.initial_seq_nr =
                    u32::from_le_bytes([shared[0], shared[1], shared[2], shared[3]]);
                for (i, byte) in self.session_key.iter_mut().enumerate() {
                    *byte = shared[i + 8] ^ auth_key[i];
                }
                // Confirmation: the watch's random, encrypted once with the
                // auth key and once with the new session key.
                let mut reply = vec![0x05];
                reply.extend_from_slice(&aes_ecb_block(auth_key, &remote_random));
                reply.extend_from_slice(&aes_ecb_block(&self.session_key, &remote_random));
                Ok(AuthStep::Reply(reply))
            }
            Some(0x05) => match payload.get(2) {
                Some(0x01) => Ok(AuthStep::Authenticated),
                Some(0x25) => Ok(AuthStep::Failure("wrong auth key")),
                other => Err(format!("session key failure: {other:02x?}")),
            },
            other => Err(format!("unknown auth cmd: {other:02x?}")),
        }
    }

    /// The negotiated session key (valid after the public-key reply).
    #[must_use]
    pub const fn session_key(&self) -> &[u8; 16] {
        &self.session_key
    }

    /// Initial encrypted-sequence number for the codec.
    #[must_use]
    pub const fn initial_seq_nr(&self) -> u32 {
        self.initial_seq_nr
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ble::auth::aes_ecb_decrypt;

    fn action_json(value: serde_json::Value) -> ControlAction {
        serde_json::from_value(value).expect("action")
    }

    #[test]
    fn action_payloads_match_gadgetbridge() {
        let start = action_json(serde_json::json!({
            "k": "hotspot_start", "ssid": "net", "password": "password1"
        }));
        let mut expected = vec![0x11];
        expected.extend_from_slice(b"net\x00password1\x00gadgetbridge\x00");
        assert_eq!(start.payload().expect("payload"), expected);
        assert_eq!(start.endpoint(), WIFI_ENDPOINT);

        let stop = action_json(serde_json::json!({ "k": "hotspot_stop" }));
        assert_eq!(stop.payload().expect("payload"), vec![0x12]);

        let ftp_start = action_json(serde_json::json!({
            "k": "ftp_start", "root_dir": "/mnt/data"
        }));
        let mut expected_ftp = vec![0x01];
        expected_ftp.extend_from_slice(b"/mnt/data\x00");
        assert_eq!(ftp_start.payload().expect("payload"), expected_ftp);
        assert_eq!(ftp_start.endpoint(), FTP_ENDPOINT);

        let ftp_stop = action_json(serde_json::json!({ "k": "ftp_stop" }));
        assert_eq!(ftp_stop.payload().expect("payload"), vec![0x02]);
    }

    #[test]
    fn action_validation() {
        let bad = action_json(serde_json::json!({
            "k": "hotspot_start", "ssid": "", "password": "password1"
        }));
        assert!(bad.payload().is_err());
        let short = action_json(serde_json::json!({
            "k": "hotspot_start", "ssid": "net", "password": "short"
        }));
        assert!(short.payload().is_err());
        // Empty root dir is valid (Gadgetbridge's original behaviour).
        let plain = action_json(serde_json::json!({ "k": "ftp_start", "root_dir": "" }));
        assert_eq!(plain.payload().expect("payload"), vec![0x01]);
    }

    #[test]
    fn parse_hotspot_states() {
        assert_eq!(
            parse_hotspot_reply(&[0x13, 0x02]),
            Ok(HotspotState::Started)
        );
        assert_eq!(
            parse_hotspot_reply(&[0x13, 0x00]),
            Ok(HotspotState::Stopped)
        );
        assert!(parse_hotspot_reply(&[0x13, 0x05]).is_err());
        assert!(parse_hotspot_reply(&[0x14, 0x02]).is_err());
    }

    #[test]
    fn parse_ftp_started_reply() {
        let mut payload = vec![0x03, 0x02];
        payload.extend_from_slice(b"192.168.44.1:21\x00");
        payload.extend_from_slice(b"testuser\x00");
        let reply = parse_ftp_reply(&payload).expect("reply");
        assert_eq!(reply.state, 0x02);
        assert_eq!(reply.address.as_deref(), Some("192.168.44.1:21"));
        assert_eq!(reply.username.as_deref(), Some("testuser"));
    }

    #[test]
    fn parse_ftp_stopped_reply() {
        let reply = parse_ftp_reply(&[0x03, 0x00]).expect("reply");
        assert_eq!(reply.state, 0x00);
        assert!(reply.address.is_none());
    }

    #[test]
    fn auth_handshake_derives_session_key() {
        // Use fixed keys so the session key derivation is checkable.
        let auth_key = [0x11u8; 16];
        // Alice (phone) starts.
        let (mut alice, start_payload) = ControlsAuth::new().expect("auth");
        assert_eq!(start_payload[0], 0x04);
        assert_eq!(start_payload[1], 0x02);
        assert_eq!(start_payload.len(), 52);

        // Bob (watch) is another ECDH party: derive his pair the same way.
        let mut bob_private = [0x42u8; 24];
        bob_private[23] = 0x7f;
        let bob_public = ecdh_b163::generate_public(&bob_private).expect("bob public");

        // Watch reply: 10 04 01 ‖ random ‖ bob public.
        let random = [0x55u8; 16];
        let mut reply = vec![0x10, 0x04, 0x01];
        reply.extend_from_slice(&random);
        reply.extend_from_slice(&bob_public);
        let AuthStep::Reply(confirm) = alice.on_payload(&reply, &auth_key).expect("step") else {
            panic!("expected confirmation reply");
        };
        assert_eq!(confirm[0], 0x05);
        assert_eq!(confirm.len(), 33);
        // First half = AES(auth_key, random), second = AES(session_key, random).
        assert_eq!(&confirm[1..17], &aes_ecb_block(&auth_key, &random));
        assert_ne!(&confirm[17..33], &aes_ecb_block(&auth_key, &random));

        // The watch would compute sessionKey the same way from its shared
        // secret; verify via the round trip: decrypt the second half with the
        // derived key and recover the random.
        let session_key = *alice.session_key();
        let mut block = [0u8; 16];
        block.copy_from_slice(&confirm[17..33]);
        assert_eq!(aes_ecb_decrypt(&session_key, &block), random);

        // Success byte completes the handshake.
        assert_eq!(
            alice
                .on_payload(&[0x10, 0x05, 0x01], &auth_key)
                .expect("step"),
            AuthStep::Authenticated
        );
        assert_eq!(
            alice
                .on_payload(&[0x10, 0x05, 0x25], &auth_key)
                .expect("step"),
            AuthStep::Failure("wrong auth key")
        );
    }
}
