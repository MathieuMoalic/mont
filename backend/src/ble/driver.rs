//! BLE relay session driver.
//!
//! Autopilot: connect (direct MAC or scan) → MTU 247 → subscribe to the FEE0
//! characteristics → legacy auth handshake on char 0x0001 → chunked
//! service-list request on endpoint 0x0000 → health fetches on 0x004b
//! (data on char 0x0005) → clean release. Every frame in both directions is
//! appended to the session recorder.

use std::collections::HashSet;
use std::time::{Duration, Instant};

use axum::extract::ws::{Message, WebSocket};
use futures_util::{SinkExt, StreamExt};
use serde_json::json;

use crate::ble::auth::{AuthOutcome, AuthSession};
use crate::ble::codec::{ChunkedDecoder, ChunkedEncoder, chunked_ack};
use crate::ble::controls::{
    AuthStep as ControlAuthStep, ControlAction, ControlsAuth, FTP_ENDPOINT, WIFI_ENDPOINT,
};
use crate::ble::fetch::{FetchEvent, FetchTracker, FetchType};
use crate::ble::parsers::{
    parse_activity_samples, parse_hr_marks, parse_hrv_samples, parse_sleep_sessions,
    parse_stress_samples,
};
use crate::ble::protocol::{
    CharacteristicInfo, EventFrame, RelayCommand, RelayEvent, ServiceInfo, command_frame,
};
use crate::ble::recorder::{FrameDir, SessionRecorder};
use crate::ble::store;
use crate::models::AppState;

/// MTU requested after connecting (matches Gadgetbridge's `allowHighMtu`).
const MTU_TARGET: u16 = 247;
/// Grace period after sending `shutdown` before closing the socket.
const SHUTDOWN_GRACE: Duration = Duration::from_secs(3);
/// Waiting for a fetch control response on 0x004b.
const FETCH_RESPONSE_TIMEOUT: Duration = Duration::from_secs(20);
/// Silence timeout while streaming data on 0x0005.
const FETCH_DATA_TIMEOUT: Duration = Duration::from_secs(30);
/// Waiting for the ack reply after we ack a transfer.
const FETCH_ACK_TIMEOUT: Duration = Duration::from_secs(20);
/// Max activity re-request rounds per session (GB uses 10).
const FETCH_MAX_ROUNDS: u32 = 20;
/// Waiting for a Wi-Fi/FTP control reply on `0x0003`/`0x0006`.
const CONTROLS_REPLY_TIMEOUT: Duration = Duration::from_secs(30);
/// Settle after a controls session completes (short — no data to flush).
const CONTROLS_SETTLE: Duration = Duration::from_secs(3);
/// How long a held transfer session keeps the watch connected before
/// force-releasing it.
const CONTROLS_HOLD_TIMEOUT: Duration = Duration::from_secs(15 * 60);
/// The only ack byte we ever send: "keep data on the watch" (0x01 would
/// delete it and advance the watch's transfer pointer).
const ACK_KEEP_DATA: u8 = 0x09;
/// Mark workouts as sent on the watch once imported (the summaries pointer
/// only advances on 0x01 — with 0x09 the watch would re-send the oldest
/// workout forever). mont stores workouts permanently, so nothing is lost.
const ACK_MARK_SENT: u8 = 0x01;

pub const AUTH_CHAR: &str = "00000001-0000-3512-2118-0009af100700";
pub const CHUNKED_WRITE_CHAR: &str = "00000016-0000-3512-2118-0009af100700";
pub const CHUNKED_READ_CHAR: &str = "00000017-0000-3512-2118-0009af100700";
pub const DATA_CHAR: &str = "00000005-0000-3512-2118-0009af100700";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Phase {
    AwaitingHello,
    Scanning,
    Connecting,
    Connected,
    Subscribed,
    Authenticating,
    /// Watch-control session: ECDH session-key exchange + Wi-Fi/FTP actions.
    Controls,
    Ready,
    Fetching,
}

#[allow(clippy::struct_excessive_bools)] // per-feature state flags
struct Session {
    state: AppState,
    recorder: SessionRecorder,
    sink: futures_util::stream::SplitSink<WebSocket, Message>,
    phase: Phase,
    cmd_id: u64,
    /// Command id of the in-flight `connect`, if any.
    pending_connect: Option<u64>,
    /// The current connect was a direct connect to the configured MAC.
    direct_connect: bool,
    /// Command ids of in-flight `subscribe`s.
    pending_subscribes: HashSet<u64>,
    auth_char_subscribed: bool,
    auth: Option<AuthSession>,
    auth_key: Option<[u8; 16]>,
    encoder: ChunkedEncoder,
    decoder: ChunkedDecoder,
    data_char_subscribed: bool,
    /// Active fetch, if any.
    fetch: Option<FetchTracker>,
    /// Remaining fetch types to run this session.
    fetch_queue: Vec<FetchType>,
    fetch_round: u32,
    fetch_retried: bool,
    fetch_deadline: Option<Instant>,
    /// Start epoch of the in-flight transfer (activity timestamping).
    fetch_start_epoch: i64,
    /// Resume point of the current fetch type (unix seconds).
    fetch_since: i64,
    fetch_results: Vec<serde_json::Value>,
    /// The `since` the current workout-details round started from — a details
    /// payload starting at-or-before this is a duplicate of an imported run.
    workout_round_base: i64,
    /// End of the last workout imported this session (non-advance guard).
    last_workout_end: Option<i64>,
    /// Set once the session milestone is reached; the session settles for
    /// `ble_settle_secs` after this, then releases the watch.
    settled_at: Option<Instant>,
    authenticated: Option<bool>,
    device_mac: Option<String>,
    device_name: Option<String>,
    notify_frames: u64,
    notify_bytes: u64,
    commands_sent: u64,
    started: Instant,
    finished: bool,
    /// Where this session was triggered from (app open, manual button, adb).
    source: String,
    /// Watch-control session: actions still to run, in order.
    control_actions: Vec<ControlAction>,
    /// With `hold_controls`: release the watch after the queued actions.
    release_after: bool,
    /// In-flight action and its reply deadline.
    pending_control: Option<(ControlAction, Instant)>,
    /// Reply deadline for the in-flight handshake/action step.
    control_deadline: Option<Instant>,
    /// The MTU the watch granted (restored after the controls handshake).
    negotiated_mtu: u16,
    /// Per-action outcome for the final `controls_result` event.
    control_results: Vec<serde_json::Value>,
    /// ECDH handshake state for the controls session.
    controls_auth: Option<ControlsAuth>,
    /// Watch-advertised per-endpoint encryption (service list on `0x0000`).
    service_encrypted: std::collections::HashMap<u16, bool>,
    /// Hold mode: keep the BLE link alive while the user transfers files
    /// (the watch drops the hotspot when the link goes down).
    hold_controls: bool,
    /// Set once the held session's start actions completed; release happens
    /// on a client `run_controls` with `release: true`, or at the timeout.
    controls_held: bool,
    /// When the held session must be force-released.
    hold_deadline: Option<Instant>,
}

/// Entry point for one relay session; runs until the socket closes or the
/// session times out. `source` records what triggered the sync (app open,
/// manual button, adb debug trigger) for the sync history.
pub async fn run_session(socket: WebSocket, state: AppState, source: String) {
    let recorder = match SessionRecorder::create(&state.config.ble_sessions_dir()) {
        Ok(r) => r,
        Err(e) => {
            tracing::error!("BLE session: cannot create session recorder: {e}");
            return;
        }
    };
    tracing::info!(
        "BLE session started, recording to {}",
        recorder.path().display()
    );
    recorder.log(FrameDir::Sys, &json!({"event": "session_start"}));

    let auth_key = state.config.ble_auth_key_bytes();
    if state.config.ble_auth_key.is_some() && auth_key.is_none() {
        tracing::error!(
            "BLE session: MONT_BLE_AUTH_KEY is set but not 32 hex chars — running transport-only"
        );
    }

    let (sink, mut stream) = socket.split();
    let mut sess = Session {
        recorder,
        sink,
        state,
        phase: Phase::AwaitingHello,
        cmd_id: 0,
        pending_connect: None,
        direct_connect: false,
        pending_subscribes: HashSet::new(),
        auth_char_subscribed: false,
        auth: None,
        auth_key,
        encoder: ChunkedEncoder::new(23),
        decoder: ChunkedDecoder::new(),
        data_char_subscribed: false,
        fetch: None,
        fetch_queue: Vec::new(),
        fetch_round: 0,
        fetch_retried: false,
        fetch_deadline: None,
        fetch_start_epoch: 0,
        fetch_since: 0,
        fetch_results: Vec::new(),
        workout_round_base: 0,
        last_workout_end: None,
        settled_at: None,
        authenticated: None,
        device_mac: None,
        device_name: None,
        notify_frames: 0,
        notify_bytes: 0,
        commands_sent: 0,
        started: Instant::now(),
        finished: false,
        source,
        control_actions: Vec::new(),
        release_after: false,
        pending_control: None,
        control_deadline: None,
        negotiated_mtu: 23,
        control_results: Vec::new(),
        controls_auth: None,
        service_encrypted: std::collections::HashMap::new(),
        hold_controls: false,
        controls_held: false,
        hold_deadline: None,
    };

    let mut tick = tokio::time::interval(Duration::from_secs(1));
    let mut shutdown_deadline: Option<Instant> = None;

    loop {
        tokio::select! {
            msg = stream.next() => {
                let cont = match msg {
                    Some(Ok(Message::Text(text))) => {
                        sess.handle_text(text.as_ref()).await
                    }
                    Some(Ok(Message::Binary(_) | Message::Ping(_) | Message::Pong(_))) => true,
                    Some(Ok(Message::Close(_))) | None => false,
                    Some(Err(e)) => {
                        tracing::warn!("BLE session ws error: {e}");
                        false
                    }
                };
                if !cont {
                    break;
                }
            }
            _ = tick.tick() => {
                if shutdown_deadline.is_some_and(|d| Instant::now() >= d) {
                    break;
                }
                if let Some(deadline) = sess.tick_timeout().await {
                    shutdown_deadline = Some(deadline);
                }
            }
        }
    }

    sess.finish().await;
}

impl Session {
    /// Handle one text frame. Returns `false` when the session should end.
    async fn handle_text(&mut self, text: &str) -> bool {
        let value: serde_json::Value = match serde_json::from_str(text) {
            Ok(v) => v,
            Err(e) => {
                tracing::debug!("BLE session: unparseable client frame: {e}");
                return true;
            }
        };
        self.recorder.log(FrameDir::C2s, &value);

        let frame: EventFrame = match serde_json::from_value(value) {
            Ok(f) => f,
            Err(e) => {
                tracing::debug!("BLE session: unknown client event: {e}");
                return true;
            }
        };
        self.handle_event(frame.event).await
    }

    /// Handle one relay event. Returns `false` when the session should end.
    #[allow(clippy::too_many_lines)] // one dispatcher, branches kept inline
    async fn handle_event(&mut self, event: RelayEvent) -> bool {
        match event {
            RelayEvent::Hello {
                platform,
                controls,
                hold,
                ..
            } => {
                tracing::info!(
                    "BLE session: client hello (platform {platform:?}, {} control actions, hold {hold})",
                    controls.len()
                );
                self.control_actions = controls;
                self.hold_controls = hold;
                if let Some(mac) = self.state.config.ble_watch_mac.clone() {
                    tracing::info!("BLE session: direct connect to configured MAC {mac}");
                    self.device_mac = Some(mac.clone());
                    let id = self.send(RelayCommand::Connect { mac }).await;
                    self.pending_connect = Some(id);
                    self.direct_connect = true;
                } else {
                    self.send(RelayCommand::ScanStart {
                        name_filter: self.state.config.ble_watch_name.clone(),
                    })
                    .await;
                }
                self.phase = if self.direct_connect {
                    Phase::Connecting
                } else {
                    Phase::Scanning
                };
            }
            RelayEvent::ScanResult { mac, name, rssi } => {
                if self.phase == Phase::Scanning
                    && let Some(name) = name.as_deref().filter(|n| self.name_matches(n))
                {
                    tracing::info!("BLE session: connecting to {name} ({mac}, rssi {rssi:?})");
                    self.device_mac = Some(mac.clone());
                    self.device_name = Some(name.to_string());
                    let id = self.send(RelayCommand::Connect { mac }).await;
                    self.pending_connect = Some(id);
                    self.phase = Phase::Connecting;
                }
            }
            RelayEvent::CmdResult { id, ok, error } => {
                if !self.handle_cmd_result(id, ok, error).await {
                    return false;
                }
            }
            RelayEvent::Connected { mtu } => {
                tracing::info!("BLE session: device connected (mtu {mtu:?})");
                self.phase = Phase::Connected;
                self.send(RelayCommand::RequestMtu { mtu: MTU_TARGET })
                    .await;
            }
            RelayEvent::Mtu { mtu } => {
                tracing::info!("BLE session: negotiated mtu {mtu}");
                self.negotiated_mtu = mtu;
                self.encoder.set_mtu(mtu);
            }
            RelayEvent::Services { services } => {
                // Control sessions subscribe like Gadgetbridge during init:
                // only the chunked READ characteristic (+ the auth char for
                // the legacy step); everything else is enabled post-auth.
                let targets: Vec<String> = if self.control_actions.is_empty() {
                    subscribable_fee0_characteristics(&services)
                } else {
                    subscribable_fee0_characteristics(&services)
                        .into_iter()
                        .filter(|uuid| {
                            uuid.eq_ignore_ascii_case(CHUNKED_READ_CHAR)
                                || uuid.eq_ignore_ascii_case(CHUNKED_WRITE_CHAR)
                                || uuid.eq_ignore_ascii_case(AUTH_CHAR)
                        })
                        .collect()
                };
                if targets.is_empty() {
                    tracing::warn!("BLE session: no subscribable FEE0 characteristics found");
                }
                for uuid in &targets {
                    tracing::info!("BLE session: subscribing to {uuid}");
                    let id = self
                        .send(RelayCommand::Subscribe {
                            char_uuid: uuid.clone(),
                        })
                        .await;
                    self.pending_subscribes.insert(id);
                    if uuid.eq_ignore_ascii_case(AUTH_CHAR) {
                        self.auth_char_subscribed = true;
                    }
                    if uuid.eq_ignore_ascii_case(DATA_CHAR) {
                        self.data_char_subscribed = true;
                    }
                }
                self.phase = Phase::Subscribed;
                if self.pending_subscribes.is_empty() {
                    self.after_subscribed().await;
                }
            }
            RelayEvent::NotifyBatch { items } => {
                for item in &items {
                    self.notify_frames += 1;
                    self.notify_bytes += item.data.len() as u64;
                    if !self.handle_notification(&item.char_uuid, &item.data).await {
                        return false;
                    }
                }
            }
            RelayEvent::Disconnected { reason } => {
                tracing::warn!(
                    "BLE session: device disconnected: {}",
                    reason.unwrap_or_else(|| "unknown reason".into())
                );
                self.send(RelayCommand::Shutdown {
                    reason: "device_disconnected".into(),
                })
                .await;
                return false;
            }
            RelayEvent::Log { msg } => {
                tracing::debug!("BLE session client: {msg}");
            }
            RelayEvent::ControlsRun { actions, release } => {
                if !self.controls_held {
                    tracing::warn!("BLE session: run_controls outside a held session, ignoring");
                    return true;
                }
                tracing::info!(
                    "BLE session: run_controls ({} actions, release {release})",
                    actions.len()
                );
                self.release_after = release;
                self.control_actions = actions;
                Box::pin(self.run_next_control_action()).await;
            }
        }
        true
    }

    /// Route one BLE notification by characteristic.
    /// Returns `false` when the session should end.
    async fn handle_notification(&mut self, char_uuid: &str, data: &[u8]) -> bool {
        if char_uuid.eq_ignore_ascii_case(AUTH_CHAR) {
            return self.handle_auth_notification(data).await;
        }
        // Bulk fetch data arrives raw on 0x0005 (counter-prefixed packets).
        if char_uuid.eq_ignore_ascii_case(DATA_CHAR) {
            return self.handle_data_packet(data).await;
        }
        // The watch sends chunked frames and acks on both the write and the
        // notify characteristic (Gadgetbridge handles both the same way).
        if char_uuid.eq_ignore_ascii_case(CHUNKED_READ_CHAR)
            || char_uuid.eq_ignore_ascii_case(CHUNKED_WRITE_CHAR)
        {
            return self.handle_chunked_notification(data).await;
        }
        true
    }

    async fn handle_auth_notification(&mut self, data: &[u8]) -> bool {
        let Some(key) = self.auth_key else {
            tracing::debug!("BLE session: auth notification but no key configured, ignoring");
            return true;
        };
        let Some(auth) = self.auth.as_mut() else {
            tracing::debug!("BLE session: auth notification outside the handshake, ignoring");
            return true;
        };
        match auth.on_response(data, &key) {
            AuthOutcome::Authenticated => {
                self.authenticated = Some(true);
                self.recorder.log(
                    FrameDir::Sys,
                    &json!({"event": "authenticated", "variant": format!("{:?}", auth_variant(data))}),
                );
                tracing::info!("BLE session: AUTHENTICATED (variant {data:02x?})");
                if !self.control_actions.is_empty() {
                    // This firmware wants the legacy char auth *before* the
                    // ZeppOS session-key exchange — now run the ECDH step.
                    tracing::info!("BLE session: controls mode — starting session-key handshake");
                    self.start_controls_handshake().await;
                    return true;
                }
                self.phase = Phase::Ready;
                self.request_service_list().await;
                self.start_fetch_phase().await;
            }
            AuthOutcome::Reply(payload) => {
                self.send_write(AUTH_CHAR, payload, false).await;
            }
            AuthOutcome::Failure(msg) => {
                self.authenticated = Some(false);
                self.recorder.log(
                    FrameDir::Sys,
                    &json!({"event": "auth_failed", "reason": msg}),
                );
                tracing::error!("BLE session: auth failed: {msg}");
                self.send(RelayCommand::Shutdown {
                    reason: "auth_failed".into(),
                })
                .await;
                return false;
            }
        }
        true
    }

    async fn handle_chunked_notification(&mut self, data: &[u8]) -> bool {
        if data.first() == Some(&0x04) {
            // Watch acknowledgement of one of our messages: {0x04, handle, count}
            tracing::debug!(
                "BLE session: watch chunked ack (handle {:#04x}, count {:#04x})",
                data.get(1).copied().unwrap_or(0),
                data.get(2).copied().unwrap_or(0)
            );
            return true;
        }
        match self.decoder.decode(data) {
            Ok(Some(msg)) => {
                self.recorder.log(
                    FrameDir::Sys,
                    &json!({
                        "event": "chunked_message",
                        "endpoint": format!("0x{:04x}", msg.endpoint),
                        "payload_len": msg.payload.len(),
                        "payload_hex": hex(&msg.payload[..msg.payload.len().min(256)]),
                        "needs_ack": msg.needs_ack,
                    }),
                );
                if msg.needs_ack {
                    let ack = chunked_ack(msg.handle, msg.count).to_vec();
                    self.send_write(CHUNKED_READ_CHAR, ack, true).await;
                }
                if msg.endpoint == 0x0000 && msg.payload.first() == Some(&0x04) {
                    if let Some(services) = parse_service_list(&msg.payload) {
                        let list: Vec<serde_json::Value> = services
                            .iter()
                            .map(|(ep, enc)| {
                                json!({"endpoint": format!("0x{ep:04x}"), "encrypted": *enc == 1})
                            })
                            .collect();
                        self.recorder.log(
                            FrameDir::Sys,
                            &json!({"event": "service_list", "services": list}),
                        );
                        tracing::info!(
                            "BLE session: service list ({} services): {}",
                            services.len(),
                            services
                                .iter()
                                .map(|(ep, enc)| format!(
                                    "0x{ep:04x}{}",
                                    if *enc == 1 { "*" } else { "" }
                                ))
                                .collect::<Vec<_>>()
                                .join(", ")
                        );
                        if !self.control_actions.is_empty() {
                            // Controls mode: follow the watch's per-endpoint
                            // encryption advertisement (GB `setEncrypted`).
                            for (ep, enc) in &services {
                                self.service_encrypted.insert(*ep, *enc == 1);
                            }
                            self.start_control_actions().await;
                        }
                    }
                } else if msg.endpoint == crate::ble::controls::AUTH_ENDPOINT {
                    return self.handle_controls_auth_payload(&msg.payload).await;
                } else if msg.endpoint == WIFI_ENDPOINT || msg.endpoint == FTP_ENDPOINT {
                    return self.handle_control_reply(msg.endpoint, &msg.payload).await;
                } else if msg.endpoint == 0x004b {
                    return self.handle_fetch_control(&msg.payload).await;
                } else {
                    tracing::debug!(
                        "BLE session: chunked message on 0x{:04x} ({} bytes)",
                        msg.endpoint,
                        msg.payload.len()
                    );
                }
            }
            Ok(None) => {}
            Err(e) => {
                tracing::debug!("BLE session: chunked decode: {e}");
            }
        }
        true
    }

    async fn request_service_list(&mut self) {
        for frame in self.encoder.encode(0x0000, &[0x03]) {
            self.send_write(CHUNKED_WRITE_CHAR, frame, true).await;
        }
    }

    async fn handle_cmd_result(&mut self, id: u64, ok: bool, error: Option<String>) -> bool {
        if ok {
            if self.pending_subscribes.remove(&id) && self.pending_subscribes.is_empty() {
                self.after_subscribed().await;
            }
            return true;
        }
        if self.pending_subscribes.remove(&id) {
            tracing::warn!("BLE session: subscribe failed: {error:?}");
            if self.pending_subscribes.is_empty() {
                self.after_subscribed().await;
            }
            return true;
        }
        if Some(id) == self.pending_connect {
            return self.handle_connect_failure(error).await;
        }
        tracing::warn!("BLE session: command {id} failed: {error:?}");
        true
    }

    async fn handle_connect_failure(&mut self, error: Option<String>) -> bool {
        let detail = error.unwrap_or_else(|| "unknown error".into());
        if self.direct_connect {
            tracing::warn!("BLE session: direct connect failed ({detail}), falling back to scan");
            self.direct_connect = false;
            self.pending_connect = None;
            self.send(RelayCommand::ScanStart {
                name_filter: self.state.config.ble_watch_name.clone(),
            })
            .await;
            self.phase = Phase::Scanning;
            return true;
        }
        tracing::error!("BLE session: connect failed: {detail}");
        self.send(RelayCommand::Shutdown {
            reason: "connect_failed".into(),
        })
        .await;
        false
    }

    /// Called once all subscribe commands have been acknowledged: start the
    /// auth handshake when possible, otherwise settle as a transport-only run.
    /// Control sessions run the legacy char auth first (this firmware rejects
    /// the session-key exchange without it), then the ECDH handshake.
    async fn after_subscribed(&mut self) {
        if self.phase != Phase::Subscribed {
            return;
        }
        if !self.control_actions.is_empty() && self.auth_key.is_none() {
            tracing::error!("BLE session: control actions need MONT_BLE_AUTH_KEY — aborting");
            self.initiate_shutdown("auth_key_required").await;
            return;
        }
        if self.auth_key.is_some() && self.auth_char_subscribed {
            tracing::info!("BLE session: starting legacy auth handshake");
            self.auth = Some(AuthSession::new());
            self.phase = Phase::Authenticating;
            self.send_write(AUTH_CHAR, AuthSession::start_request(), false)
                .await;
            return;
        }
        if !self.control_actions.is_empty() {
            tracing::error!("BLE session: auth char unsubscribed — cannot run controls handshake");
            self.initiate_shutdown("auth_unavailable").await;
            return;
        }
        tracing::info!(
            "BLE session: no auth key configured (or auth char unsubscribed) — transport-only run"
        );
        self.phase = Phase::Ready;
        self.settled_at = Some(Instant::now());
    }

    /// Kick off the `0x0082` ECDH session-key handshake (controls sessions).
    ///
    /// The handshake runs at MTU 23 (Gadgetbridge #3219: "Reset the MTU
    /// before re-initializing the device, otherwise initialization will
    /// sometimes fail") — the watch's auth path mishandles large frames.
    async fn start_controls_handshake(&mut self) {
        self.encoder.set_mtu(23);
        match ControlsAuth::new() {
            Ok((auth, start_payload)) => {
                self.controls_auth = Some(auth);
                self.phase = Phase::Controls;
                self.control_deadline_set();
                tracing::info!("BLE session: starting ZeppOS session-key handshake (0x0082)");
                for frame in self
                    .encoder
                    .encode(crate::ble::controls::AUTH_ENDPOINT, &start_payload)
                {
                    self.send_write(CHUNKED_WRITE_CHAR, frame, true).await;
                }
            }
            Err(e) => {
                tracing::error!("BLE session: controls setup failed: {e}");
                self.initiate_shutdown("controls_setup_failed").await;
            }
        }
    }

    // ── watch controls (Wi-Fi hotspot / FTP) ──────────────────────────────────

    fn control_deadline_set(&mut self) {
        self.control_deadline = Some(Instant::now() + CONTROLS_REPLY_TIMEOUT);
    }

    /// Feed one `0x0082` payload (ECDH session-key handshake).
    /// Returns `false` when the session should end.
    async fn handle_controls_auth_payload(&mut self, payload: &[u8]) -> bool {
        let Some(auth_key) = self.auth_key else {
            return true;
        };
        let Some(auth) = self.controls_auth.as_mut() else {
            return true;
        };
        match auth.on_payload(payload, &auth_key) {
            Ok(ControlAuthStep::Reply(reply)) => {
                // Session key is derived — activate the codec cipher now so
                // the confirmation and everything after it is protected.
                let session_key = *auth.session_key();
                let seq_nr = auth.initial_seq_nr();
                self.encoder.set_encryption_parameters(seq_nr, session_key);
                self.decoder.set_session_key(session_key);
                tracing::info!(
                    "BLE session: session key derived (seq {seq_nr}), sending confirmation"
                );
                for frame in self
                    .encoder
                    .encode(crate::ble::controls::AUTH_ENDPOINT, &reply)
                {
                    self.send_write(CHUNKED_WRITE_CHAR, frame, true).await;
                }
                true
            }
            Ok(ControlAuthStep::Authenticated) => {
                self.control_deadline = None;
                self.encoder.set_mtu(self.negotiated_mtu);
                self.recorder
                    .log(FrameDir::Sys, &json!({"event": "controls_authenticated"}));
                tracing::info!("BLE session: watch controls AUTHENTICATED");
                self.request_service_list().await;
                true
            }
            Ok(ControlAuthStep::Failure(msg)) => {
                tracing::error!("BLE session: controls auth failed: {msg}");
                self.initiate_shutdown("controls_auth_failed").await;
                false
            }
            Err(e) => {
                tracing::error!("BLE session: controls auth protocol error: {e}");
                self.initiate_shutdown("controls_auth_error").await;
                false
            }
        }
    }

    /// Run the queued control actions (after the service list arrived).
    async fn start_control_actions(&mut self) {
        for endpoint in [WIFI_ENDPOINT, FTP_ENDPOINT] {
            self.service_encrypted.entry(endpoint).or_insert(true);
        }
        self.run_next_control_action().await;
    }

    /// Pop the next action and send it (or finish the session).
    async fn run_next_control_action(&mut self) {
        self.control_deadline = None;
        let Some(action) = self.control_actions.first().cloned() else {
            self.controls_complete().await;
            return;
        };
        self.control_actions.remove(0);
        let Ok(payload) = action.payload() else {
            let e = action.payload().err().unwrap_or_default();
            tracing::error!("BLE session: invalid control action {}: {e}", action.name());
            self.control_results.push(json!({
                "action": action.name(),
                "status": "invalid",
                "error": e,
            }));
            Box::pin(self.run_next_control_action()).await;
            return;
        };
        let endpoint = action.endpoint();
        if !self.service_encrypted.contains_key(&endpoint) {
            tracing::error!(
                "BLE session: watch does not advertise endpoint 0x{endpoint:04x} — skipping {}",
                action.name()
            );
            self.control_results.push(json!({
                "action": action.name(),
                "status": "unsupported",
                "error": format!("endpoint 0x{endpoint:04x} not advertised by the watch"),
            }));
            Box::pin(self.run_next_control_action()).await;
            return;
        }
        let encrypted = self
            .service_encrypted
            .get(&endpoint)
            .copied()
            .unwrap_or(true);
        let frames = if encrypted && self.encoder.has_session_key() {
            self.encoder.encode_encrypted(endpoint, &payload)
        } else {
            Ok(self.encoder.encode(endpoint, &payload))
        };
        match frames {
            Ok(frames) => {
                tracing::info!(
                    "BLE session: control action {} (endpoint 0x{endpoint:04x}, encrypted {encrypted})",
                    action.name()
                );
                self.pending_control = Some((action, Instant::now() + CONTROLS_REPLY_TIMEOUT));
                for frame in frames {
                    self.send_write(CHUNKED_WRITE_CHAR, frame, true).await;
                }
            }
            Err(e) => {
                tracing::error!("BLE session: control encode failed: {e}");
                self.control_results.push(json!({
                    "action": action.name(),
                    "status": "error",
                    "error": e,
                }));
                Box::pin(self.run_next_control_action()).await;
            }
        }
    }

    /// Handle a Wi-Fi (`0x13`) or FTP (`0x03`) reply.
    async fn handle_control_reply(&mut self, endpoint: u16, payload: &[u8]) -> bool {
        let Some((action, _)) = self.pending_control.take() else {
            tracing::debug!(
                "BLE session: control reply on 0x{endpoint:04x} with no pending action"
            );
            return true;
        };
        self.control_deadline = None;
        let mut result = json!({"action": action.name(), "status": "ok"});
        if endpoint == WIFI_ENDPOINT {
            match super::controls::parse_hotspot_reply(payload) {
                Ok(state) => {
                    result["state"] = json!(match state {
                        super::controls::HotspotState::Started => "started",
                        super::controls::HotspotState::Stopped => "stopped",
                    });
                    tracing::info!("BLE session: hotspot {} → {state:?}", action.name());
                }
                Err(e) => {
                    result["status"] = json!("error");
                    result["error"] = json!(e);
                }
            }
        } else {
            match super::controls::parse_ftp_reply(payload) {
                Ok(reply) => {
                    result["state"] = json!(if reply.state == 0x02 {
                        "started"
                    } else {
                        "stopped"
                    });
                    if let Some(address) = &reply.address {
                        result["address"] = json!(address);
                    }
                    if let Some(username) = &reply.username {
                        result["username"] = json!(username);
                    }
                    tracing::info!(
                        "BLE session: ftp {} → state {:02x} address {:?} user {:?}",
                        action.name(),
                        reply.state,
                        reply.address,
                        reply.username
                    );
                }
                Err(e) => {
                    result["status"] = json!("error");
                    result["error"] = json!(e);
                }
            }
        }
        self.control_results.push(result);
        self.run_next_control_action().await;
        true
    }

    /// All actions done: report to the client. Held sessions stay connected
    /// (the watch drops the hotspot when the BLE link goes down) until the
    /// client releases them or the hold timeout hits.
    async fn controls_complete(&mut self) {
        let results = self.control_results.clone();
        tracing::info!(
            "BLE session: control actions complete ({} results)",
            results.len()
        );
        self.send(RelayCommand::ControlsResult { results }).await;
        self.recorder.log(
            FrameDir::Sys,
            &json!({"event": "controls_result", "results": self.control_results}),
        );
        if self.hold_controls && !self.release_after {
            self.controls_held = true;
            self.hold_deadline = Some(Instant::now() + CONTROLS_HOLD_TIMEOUT);
            tracing::info!(
                "BLE session: holding the watch for the transfer ({} min cap)",
                CONTROLS_HOLD_TIMEOUT.as_secs() / 60
            );
        } else {
            self.settled_at = Some(Instant::now());
        }
    }

    // ── health fetch engine ───────────────────────────────────────────────────

    /// Queue the health fetches (after authentication).
    async fn start_fetch_phase(&mut self) {
        if !self.state.config.ble_fetch_enabled || !self.data_char_subscribed {
            tracing::info!(
                "BLE session: fetch disabled (enabled={}, data char subscribed={}) — settling",
                self.state.config.ble_fetch_enabled,
                self.data_char_subscribed
            );
            self.settled_at = Some(Instant::now());
            return;
        }
        // popped from the back — quick types first, then activity, workouts last
        // (workouts enumerate via 0x06 details: this firmware's 0x05 ignores
        // `since` and always returns its oldest summary)
        self.fetch_queue = vec![
            FetchType::SportsDetails,
            FetchType::SleepSession,
            FetchType::Activity,
            FetchType::Stress,
            FetchType::Hrv,
            FetchType::MaxHr,
            FetchType::RestingHr,
        ];
        self.next_fetch().await;
    }

    /// Pop the next fetch type and send its request.
    async fn next_fetch(&mut self) {
        self.phase = Phase::Ready;
        self.fetch_deadline = None;
        let Some(fetch_type) = self.fetch_queue.pop() else {
            tracing::info!("BLE session: all fetches done, settling");
            self.settled_at = Some(Instant::now());
            return;
        };
        self.fetch_round = 0;
        self.fetch_retried = false;
        self.fetch_since = 0; // per type — the first round loads the stored pointer
        self.begin_fetch_round(fetch_type).await;
    }

    /// Send a request for `fetch_type` starting at its resume point.
    async fn begin_fetch_round(&mut self, fetch_type: FetchType) {
        let now = chrono::Utc::now().timestamp();
        let lookback = self.state.config.ble_fetch_lookback_days * 86_400;
        // Resume exactly at the end of the previous batch (GB semantics — an
        // overlap here cancels against the batch end and stalls the loop).
        let since = if self.fetch_since > 0 {
            self.fetch_since
        } else {
            let last = store::load_sync_state(&self.state.pool, fetch_type.id())
                .await
                .unwrap_or(0);
            if last > 0 { last } else { now - lookback }
        };
        self.fetch_since = since;
        if fetch_type == FetchType::SportsDetails {
            // remember the window start: details starting at-or-before this
            // are duplicates of already-imported workouts
            self.workout_round_base = since;
        }

        let tz = local_tz_quarter_hours();
        let payload = FetchTracker::build_request(fetch_type, since, tz);
        tracing::info!(
            "BLE session: fetching {fetch_type:?} since {} (round {})",
            store::utc_date(since),
            self.fetch_round + 1
        );
        self.fetch = Some(FetchTracker::new(fetch_type));
        self.phase = Phase::Fetching;
        self.fetch_deadline = Some(Instant::now() + FETCH_RESPONSE_TIMEOUT);
        self.recorder.log(
            FrameDir::Sys,
            &json!({"event": "fetch_request", "type": fetch_type.id(), "since": since}),
        );
        for frame in self.encoder.encode(0x004b, &payload) {
            self.send_write(CHUNKED_WRITE_CHAR, frame, true).await;
        }
    }

    /// Handle one control payload from the fetch endpoint 0x004b.
    /// Returns `false` when the session should end.
    async fn handle_fetch_control(&mut self, payload: &[u8]) -> bool {
        let Some(fetch) = self.fetch.as_mut() else {
            tracing::debug!("BLE session: 0x004b payload with no active fetch, ignoring");
            return true;
        };
        let fetch_type = fetch.fetch_type();
        let Some(event) = fetch.on_control(payload) else {
            return true;
        };
        match event {
            FetchEvent::NoData => self.handle_fetch_no_data(fetch_type).await,
            FetchEvent::Response {
                expected_len,
                start_epoch,
            } => {
                tracing::info!(
                    "BLE session: {fetch_type:?}: transferring {expected_len} bytes since {}",
                    store::utc_date(start_epoch)
                );
                self.fetch_start_epoch = start_epoch;
                self.fetch_deadline = Some(Instant::now() + FETCH_DATA_TIMEOUT);
                // {0x02} = start the data transfer
                for frame in self.encoder.encode(0x004b, &[0x02]) {
                    self.send_write(CHUNKED_WRITE_CHAR, frame, true).await;
                }
            }
            FetchEvent::Complete { payload, crc_ok } => {
                if crc_ok == Some(false) {
                    tracing::error!(
                        "BLE session: {fetch_type:?}: CRC mismatch — dropping batch, keeping data on watch"
                    );
                    self.fetch_results.push(json!({
                        "type": fetch_type.id(), "status": "crc_error",
                    }));
                } else if let Err(e) = self.store_fetch_payload(fetch_type, &payload).await {
                    tracing::error!("BLE session: {fetch_type:?}: store failed: {e}");
                    self.fetch_results.push(json!({
                        "type": fetch_type.id(), "status": "store_error", "error": e,
                    }));
                }
                self.send_fetch_ack(Self::ack_byte_for(fetch_type)).await;
                // tracker stays alive for the ack reply
            }
            FetchEvent::Acked => {
                self.fetch = None;
                self.fetch_deadline = None;
                match fetch_type {
                    FetchType::Activity => {
                        // Activity fetches repeat until caught up.
                        if self.wants_another_round(FetchType::Activity) {
                            self.fetch_round += 1;
                            if self.fetch_round < FETCH_MAX_ROUNDS {
                                self.begin_fetch_round(FetchType::Activity).await;
                                return true;
                            }
                            tracing::warn!("BLE session: activity fetch hit the round cap");
                        }
                        self.next_fetch().await;
                    }
                    FetchType::SportsDetails => {
                        // workout loop: keep walking while the last details
                        // payload ended before now
                        if self.wants_another_round(FetchType::SportsDetails)
                            && self.fetch_round < FETCH_MAX_ROUNDS
                        {
                            self.fetch_round += 1;
                            self.begin_fetch_round(FetchType::SportsDetails).await;
                        } else {
                            if self.fetch_round >= FETCH_MAX_ROUNDS {
                                tracing::warn!("BLE session: workout loop hit the round cap");
                            }
                            self.next_fetch().await;
                        }
                    }
                    _ => self.next_fetch().await,
                }
            }
        }
        true
    }

    /// "No data" from the watch means we are caught up — advance the pointer
    /// so the catch-up loop terminates, then ack (the tracker stays alive; the
    /// ack reply moves us on).
    async fn handle_fetch_no_data(&mut self, fetch_type: FetchType) {
        tracing::info!("BLE session: {fetch_type:?}: no data");
        if matches!(
            fetch_type,
            FetchType::Activity | FetchType::Stress | FetchType::SportsDetails
        ) {
            let now = chrono::Utc::now().timestamp();
            self.fetch_since = now;
            if let Err(e) =
                store::update_sync_state(&self.state.pool, fetch_type.id(), now, ACK_KEEP_DATA)
                    .await
            {
                tracing::error!("BLE session: sync state update failed: {e}");
            }
        }
        self.fetch_results
            .push(json!({"type": fetch_type.id(), "status": "no_data"}));
        self.send_fetch_ack(Self::ack_byte_for(fetch_type)).await;
    }

    /// Whether another round of `fetch_type` is needed to catch up to now.
    fn wants_another_round(&self, fetch_type: FetchType) -> bool {
        match fetch_type {
            FetchType::Activity | FetchType::Stress | FetchType::SportsDetails => {
                let now = chrono::Utc::now().timestamp();
                self.fetch_since + 120 < now
            }
            _ => false,
        }
    }

    /// Feed one raw data packet from characteristic 0x0005.
    async fn handle_data_packet(&mut self, data: &[u8]) -> bool {
        let Some(fetch) = self.fetch.as_mut() else {
            return true;
        };
        if let Err(e) = fetch.on_data(data) {
            tracing::error!("BLE session: fetch data error: {e}");
            self.fetch = None;
            self.fetch_deadline = None;
            // Abort this type; keep-data policy means nothing is lost.
            self.fetch_results
                .push(json!({"status": "data_error", "error": e}));
            self.next_fetch().await;
            return true;
        }
        self.fetch_deadline = Some(Instant::now() + FETCH_DATA_TIMEOUT);
        true
    }

    /// Ack the current transfer. `0x09` keeps the data on the watch (health
    /// windows stay re-fetchable); `0x01` marks workouts as sent — required,
    /// or the watch re-sends the oldest summary forever.
    async fn send_fetch_ack(&mut self, ack_byte: u8) {
        self.fetch_deadline = Some(Instant::now() + FETCH_ACK_TIMEOUT);
        for frame in self.encoder.encode(0x004b, &[0x03, ack_byte]) {
            self.send_write(CHUNKED_WRITE_CHAR, frame, true).await;
        }
    }

    /// The ack byte for a fetch type: workouts are marked sent after import.
    const fn ack_byte_for(fetch_type: FetchType) -> u8 {
        match fetch_type {
            FetchType::SportsSummaries | FetchType::SportsDetails => ACK_MARK_SENT,
            _ => ACK_KEEP_DATA,
        }
    }

    /// Parse and store a completed fetch payload.
    async fn store_fetch_payload(
        &mut self,
        fetch_type: FetchType,
        payload: &[u8],
    ) -> Result<(), String> {
        let start = self.fetch_start_epoch;
        match fetch_type {
            FetchType::Activity => {
                let samples = parse_activity_samples(payload, start)
                    .map_err(|_| "activity payload not a multiple of 8".to_string())?;
                let count = samples.len();
                let dates = store::store_activity_samples(&self.state.pool, &samples)
                    .await
                    .map_err(|e| e.to_string())?;
                store::refresh_daily_health(&self.state.pool, &dates)
                    .await
                    .map_err(|e| e.to_string())?;
                let last_ts = start + i64::try_from(count).unwrap_or(0) * 60;
                store::update_sync_state(&self.state.pool, fetch_type.id(), last_ts, ACK_KEEP_DATA)
                    .await
                    .map_err(|e| e.to_string())?;
                if last_ts <= self.fetch_since {
                    // The watch re-sent the same window — treat as caught up.
                    tracing::info!(
                        "BLE session: activity fetch made no progress (window ends {last_ts}) — treating as caught up"
                    );
                    self.fetch_since = chrono::Utc::now().timestamp();
                    store::update_sync_state(
                        &self.state.pool,
                        fetch_type.id(),
                        self.fetch_since,
                        ACK_KEEP_DATA,
                    )
                    .await
                    .map_err(|e| e.to_string())?;
                } else {
                    self.fetch_since = last_ts;
                }
                tracing::info!(
                    "BLE session: stored {count} activity samples ({count} min) covering {}..{}",
                    store::utc_date(start),
                    dates
                        .last()
                        .map_or_else(|| store::utc_date(start), Clone::clone)
                );
                self.fetch_results.push(json!({
                    "type": fetch_type.id(), "status": "ok", "samples": count,
                    "dates": dates,
                }));
            }
            FetchType::RestingHr | FetchType::MaxHr => {
                let marks = parse_hr_marks(payload)
                    .map_err(|_| "hr marks payload not a multiple of 6".to_string())?;
                let count = marks.len();
                store::store_hr_marks(&self.state.pool, &marks, fetch_type == FetchType::MaxHr)
                    .await
                    .map_err(|e| e.to_string())?;
                let last = marks.last().map_or(self.fetch_since, |m| m.epoch + 60);
                store::update_sync_state(&self.state.pool, fetch_type.id(), last, ACK_KEEP_DATA)
                    .await
                    .map_err(|e| e.to_string())?;
                tracing::info!("BLE session: stored {count} {fetch_type:?} marks");
                self.fetch_results.push(json!({
                    "type": fetch_type.id(), "status": "ok", "records": count,
                }));
            }
            FetchType::Hrv => {
                let samples = parse_hrv_samples(payload)
                    .map_err(|_| "hrv payload not a multiple of 6".to_string())?;
                let count = samples.len();
                let dates = store::store_hrv_samples(&self.state.pool, &samples)
                    .await
                    .map_err(|e| e.to_string())?;
                store::refresh_daily_health(&self.state.pool, &dates)
                    .await
                    .map_err(|e| e.to_string())?;
                let last = samples.last().map_or(self.fetch_since, |s| s.ts + 60);
                store::update_sync_state(&self.state.pool, fetch_type.id(), last, ACK_KEEP_DATA)
                    .await
                    .map_err(|e| e.to_string())?;
                tracing::info!("BLE session: stored {count} HRV samples");
                self.fetch_results.push(json!({
                    "type": fetch_type.id(), "status": "ok", "samples": count,
                    "dates": dates,
                }));
            }
            FetchType::Stress => {
                self.store_stress_payload(payload, start).await?;
            }
            FetchType::SleepSession => {
                self.store_sleep_session_payload(payload).await?;
            }
            FetchType::SportsDetails => {
                self.store_workout_details(payload).await?;
            }
            // unused: this firmware's 0x05 ignores `since` and always returns
            // its oldest summary, so workouts enumerate via 0x06 instead
            FetchType::SportsSummaries => {}
        }
        Ok(())
    }

    /// Parse and store one 0x48 sleep-session payload (594-byte records);
    /// the pointer advances past the newest session.
    async fn store_sleep_session_payload(&mut self, payload: &[u8]) -> Result<(), String> {
        let sessions = parse_sleep_sessions(payload)
            .map_err(|_| "sleep payload not a multiple of 594".to_string())?;
        let count = sessions.len();
        store::store_sleep_sessions(&self.state.pool, &sessions)
            .await
            .map_err(|e| e.to_string())?;
        let last = sessions.last().map_or(self.fetch_since, |s| s.ts + 60);
        store::update_sync_state(
            &self.state.pool,
            FetchType::SleepSession.id(),
            last,
            ACK_KEEP_DATA,
        )
        .await
        .map_err(|e| e.to_string())?;
        tracing::info!("BLE session: stored {count} sleep sessions");
        self.fetch_results.push(json!({
            "type": FetchType::SleepSession.id(), "status": "ok", "samples": count,
        }));
        Ok(())
    }

    /// Parse and store a stress-auto payload (1 byte per minute); advance the
    /// pointer past it, or mark caught up when the watch re-sends the window.
    async fn store_stress_payload(&mut self, payload: &[u8], start: i64) -> Result<(), String> {
        let samples = parse_stress_samples(payload, start);
        let count = samples.len();
        store::store_stress_samples(&self.state.pool, &samples)
            .await
            .map_err(|e| e.to_string())?;
        let last_ts = start + i64::try_from(count).unwrap_or(0) * 60;
        store::update_sync_state(
            &self.state.pool,
            FetchType::Stress.id(),
            last_ts,
            ACK_KEEP_DATA,
        )
        .await
        .map_err(|e| e.to_string())?;
        if last_ts <= self.fetch_since {
            // watch re-sent the same window — treat as caught up
            tracing::info!("BLE session: stress fetch made no progress — treating as caught up");
            self.fetch_since = chrono::Utc::now().timestamp();
            store::update_sync_state(
                &self.state.pool,
                FetchType::Stress.id(),
                self.fetch_since,
                ACK_KEEP_DATA,
            )
            .await
            .map_err(|e| e.to_string())?;
        } else {
            self.fetch_since = last_ts;
        }
        tracing::info!("BLE session: stored {count} stress samples");
        self.fetch_results.push(json!({
            "type": FetchType::Stress.id(), "status": "ok", "samples": count,
        }));
        Ok(())
    }

    /// Parse one 0x06 details payload: this is the workout importer. The
    /// payload's TIMESTAMP TLV gives the workout start, the track points give
    /// duration/distance/HR, and the GPS route attaches to the run. The
    /// pointer advances strictly past the workout so the next round enumerates
    /// the next one.
    async fn store_workout_details(&mut self, payload: &[u8]) -> Result<(), String> {
        let Some(parsed) = crate::routes::runs::parse_zeppos_raw_details_bin(payload) else {
            tracing::info!(
                "BLE session: no usable GPS points in details payload ({} bytes) — skipping",
                payload.len()
            );
            return Ok(());
        };
        let start = parsed.start_epoch.unwrap_or(self.fetch_start_epoch);
        let last_t = parsed.route.last().and_then(|p| p.t).unwrap_or(0);
        let end = start + last_t;
        let source_file = format!("ble-{}", store::rfc3339_utc(start));
        tracing::info!(
            "BLE session: workout details: start={} points={} duration={last_t}s distance={:.0}m hr={:?}/{}",
            store::utc_date(start),
            parsed.route.len(),
            parsed.distance_m,
            parsed.avg_hr,
            parsed.max_hr.unwrap_or(0)
        );

        // the watch's workout filter appears to be DAY-granular (END >= start
        // of since's day): a workout may be re-sent when since falls on the
        // same day. Handle both cases:
        // - re-send of a workout starting at-or-before this round's since →
        //   jump the pointer to the next day boundary and keep walking
        //   (duplicate: already imported, nothing to do)
        // - workout entirely behind the window → caught up
        let start_before_window = start <= self.workout_round_base;
        let entirely_behind = end <= self.workout_round_base;
        if start_before_window || entirely_behind {
            if start_before_window {
                let next_day = (start.div_euclid(86_400) + 1) * 86_400;
                tracing::info!(
                    "BLE session: re-sent known workout (start {} <= since {}) — jumping to {}",
                    store::utc_date(start),
                    store::utc_date(self.workout_round_base),
                    store::utc_date(next_day)
                );
                self.fetch_since = next_day;
            } else {
                tracing::info!("BLE session: workout ends before the window — caught up");
                self.fetch_since = chrono::Utc::now().timestamp();
            }
            store::update_sync_state(
                &self.state.pool,
                FetchType::SportsDetails.id(),
                self.fetch_since,
                ACK_KEEP_DATA,
            )
            .await
            .map_err(|e| e.to_string())?;
            self.fetch_results.push(json!({
                "type": FetchType::SportsDetails.id(),
                "status": if start_before_window { "duplicate" } else { "behind_window" },
            }));
            return Ok(());
        }

        let workout = store::BleWorkout {
            source_file: source_file.clone(),
            started_at: store::rfc3339_utc(start),
            duration_s: last_t,
            distance_m: parsed.distance_m,
            avg_hr: parsed.avg_hr.filter(|h| (1..255).contains(h)),
            max_hr: parsed.max_hr.filter(|h| (1..255).contains(h)),
            avg_cadence: parsed.avg_cadence,
            avg_stride_m: parsed.avg_stride_m,
            calories: crate::routes::runs::estimate_calories(
                parsed.distance_m,
                last_t,
                parsed.avg_hr,
            ),
        };
        store::upsert_ble_run(&self.state.pool, &workout)
            .await
            .map_err(|e| e.to_string())?;
        self.attach_route_and_weather(&source_file, start, &parsed)
            .await?;

        // advance STRICTLY past this workout: the watch's filter is
        // end-inclusive, so requesting since=end re-returns the same workout.
        // A re-served identical workout means the watch isn't advancing —
        // stop the loop (imports are idempotent; nothing is lost).
        if self.last_workout_end == Some(end) {
            tracing::info!("BLE session: workout loop not advancing — caught up");
            self.fetch_since = chrono::Utc::now().timestamp();
        } else {
            self.last_workout_end = Some(end);
            self.fetch_since = end + 60;
        }
        store::update_sync_state(
            &self.state.pool,
            FetchType::SportsDetails.id(),
            self.fetch_since,
            ACK_KEEP_DATA,
        )
        .await
        .map_err(|e| e.to_string())?;
        tracing::info!(
            "BLE session: run imported ({source_file}, {} points)",
            parsed.route.len()
        );
        self.fetch_results.push(json!({
            "type": FetchType::SportsDetails.id(), "status": "ok",
            "start": source_file, "route_points": parsed.route.len(),
            "duration_s": last_t, "distance_m": parsed.distance_m,
        }));
        Ok(())
    }

    /// Attach the GPS route, elevation and weather to an imported run.
    async fn attach_route_and_weather(
        &self,
        source_file: &str,
        start: i64,
        parsed: &crate::routes::runs::ParsedRawDetailsRun,
    ) -> Result<(), String> {
        let route_json = serde_json::to_string(&parsed.route).map_err(|e| e.to_string())?;
        let weather = if let Some(p) = parsed.route.first() {
            crate::weather::fetch_weather(&self.state.http, p.lat, p.lon, start).await
        } else {
            None
        };
        store::update_run_route(
            &self.state.pool,
            source_file,
            &route_json,
            parsed.elevation_gain_m,
            parsed.distance_m,
            weather,
        )
        .await
        .map_err(|e| e.to_string())
    }
    /// Handle an expired fetch deadline (the watch silently ignores requests
    /// older than its transfer pointer — retry once from a newer date).
    async fn fetch_deadline_hit(&mut self) {
        let Some(fetch) = self.fetch.take() else {
            self.fetch_deadline = None;
            return;
        };
        let fetch_type = fetch.fetch_type();
        self.fetch_deadline = None;
        if fetch_type == FetchType::Activity && !self.fetch_retried {
            // maybe mid-transfer stall: one fresh round from a newer date
            self.fetch_retried = true;
            self.fetch_round += 1;
            tracing::warn!("BLE session: {fetch_type:?} timed out, retrying from yesterday");
            self.begin_fetch_round(fetch_type).await;
            return;
        }
        if !self.fetch_retried {
            // Retry once from yesterday — covers the watch pointer quirk.
            self.fetch_retried = true;
            self.fetch_round += 1;
            tracing::warn!("BLE session: {fetch_type:?} timed out, retrying from yesterday");
            self.begin_fetch_round(fetch_type).await;
            return;
        }
        tracing::error!("BLE session: {fetch_type:?} timed out again — skipping");
        self.fetch_results
            .push(json!({"type": fetch_type.id(), "status": "timeout"}));
        self.next_fetch().await;
    }

    /// Check session timeouts. Returns `Some(shutdown deadline)` when a shutdown
    /// was initiated.
    async fn tick_timeout(&mut self) -> Option<Instant> {
        if self.finished {
            return None;
        }
        if let Some(deadline) = self.control_deadline
            && Instant::now() >= deadline
        {
            self.control_deadline = None;
            if let Some((action, _)) = self.pending_control.take() {
                tracing::error!("BLE session: control action {} timed out", action.name());
                self.control_results.push(json!({
                    "action": action.name(),
                    "status": "timeout",
                }));
                self.run_next_control_action().await;
            }
        }
        if let Some(deadline) = self.hold_deadline
            && Instant::now() >= deadline
        {
            tracing::warn!("BLE session: controls hold timeout — releasing the watch");
            self.hold_deadline = None;
            self.initiate_shutdown("hold_timeout").await;
            return Some(Instant::now() + SHUTDOWN_GRACE);
        }
        if self.fetch_deadline.is_some_and(|d| Instant::now() >= d) {
            self.fetch_deadline_hit().await;
        }
        let timeout = Duration::from_secs(self.state.config.ble_session_timeout_secs);
        if self.started.elapsed() > timeout {
            tracing::warn!("BLE session: overall timeout reached");
            self.initiate_shutdown("session_timeout").await;
            return Some(Instant::now() + SHUTDOWN_GRACE);
        }
        let settle = if self.is_controls_session() {
            CONTROLS_SETTLE
        } else {
            Duration::from_secs(self.state.config.ble_settle_secs)
        };
        if self.settled_at.is_some_and(|t| t.elapsed() > settle) {
            tracing::info!("BLE session: settle period complete, releasing device");
            if !self.finished {
                self.send(RelayCommand::DisconnectDevice).await;
            }
            self.initiate_shutdown("session_complete").await;
            return Some(Instant::now() + SHUTDOWN_GRACE);
        }
        None
    }

    /// Whether this session is a watch-control session (not a health sync).
    #[must_use]
    const fn is_controls_session(&self) -> bool {
        !self.control_actions.is_empty()
            || self.pending_control.is_some()
            || self.controls_auth.is_some()
            || !self.control_results.is_empty()
    }

    fn name_matches(&self, name: &str) -> bool {
        let filter = &self.state.config.ble_watch_name;
        if filter.is_empty() {
            return !name.is_empty();
        }
        name.to_lowercase().contains(&filter.to_lowercase())
    }

    /// Send a command to the client and record it. Returns the command id.
    async fn send(&mut self, command: RelayCommand) -> u64 {
        self.cmd_id += 1;
        self.commands_sent += 1;
        let frame = command_frame(self.cmd_id, command);
        let Ok(text) = serde_json::to_string(&frame) else {
            return self.cmd_id;
        };
        self.recorder.log(
            FrameDir::S2c,
            &serde_json::to_value(&frame).unwrap_or_default(),
        );
        let _ = self.sink.send(Message::text(text)).await;
        self.cmd_id
    }

    async fn send_write(&mut self, char_uuid: &str, data: Vec<u8>, without_response: bool) {
        self.send(RelayCommand::Write {
            char_uuid: char_uuid.to_string(),
            data,
            without_response,
        })
        .await;
    }

    async fn initiate_shutdown(&mut self, reason: &str) {
        if self.finished {
            return;
        }
        self.finished = true;
        self.send(RelayCommand::Shutdown {
            reason: reason.to_string(),
        })
        .await;
    }

    async fn finish(&mut self) {
        self.persist_sync_log().await;
        let summary = json!({
            "event": "session_end",
            "phase": format!("{:?}", self.phase),
            "authenticated": self.authenticated,
            "device": self.device_mac,
            "device_name": self.device_name,
            "notify_frames": self.notify_frames,
            "notify_bytes": self.notify_bytes,
            "commands_sent": self.commands_sent,
            "fetch_results": self.fetch_results,
            "duration_s": self.started.elapsed().as_secs(),
        });
        self.recorder.log(FrameDir::Sys, &summary);
        tracing::info!(
            "BLE session ended: phase={:?} authenticated={:?} device={:?} notify_frames={} notify_bytes={} cmds={} fetches={} duration={}s file={}",
            self.phase,
            self.authenticated,
            self.device_name,
            self.notify_frames,
            self.notify_bytes,
            self.commands_sent,
            self.fetch_results.len(),
            self.started.elapsed().as_secs(),
            self.recorder.path().display()
        );
        let _ = self.sink.close().await;
    }

    /// Persist the sync history: one `ble_sync_log` row per meaningful fetch
    /// result (imports and failures; "no data" / duplicates are noise), plus a
    /// session-level failure row when a sync never got far enough to fetch.
    #[allow(clippy::too_many_lines)] // row-mapping kept in one place
    async fn persist_sync_log(&self) {
        let now = store::rfc3339_utc(chrono::Utc::now().timestamp());
        let mut entries: Vec<store::SyncLogEntry> = Vec::new();
        for r in &self.control_results {
            let status = r["status"].as_str().unwrap_or("unknown");
            let detail = match status {
                "ok" => {
                    let mut parts = vec![r["action"].as_str().unwrap_or("").to_string()];
                    if let Some(address) = r["address"].as_str() {
                        parts.push(format!("ftp {address}"));
                    }
                    if let Some(username) = r["username"].as_str() {
                        parts.push(format!("user {username}"));
                    }
                    if let Some(state) = r["state"].as_str() {
                        parts.push(state.to_string());
                    }
                    parts.join(" · ")
                }
                other => format!(
                    "{}: {}",
                    r["action"].as_str().unwrap_or(""),
                    r["error"].as_str().unwrap_or(other)
                ),
            };
            entries.push(store::SyncLogEntry {
                ts: now.clone(),
                source: self.source.clone(),
                kind: "watch_transfer".to_string(),
                status: status.to_string(),
                stored: 0,
                detail,
            });
        }
        for r in &self.fetch_results {
            let status = r["status"].as_str().unwrap_or("unknown");
            let kind =
                FetchType::name_for_id(u8::try_from(r["type"].as_u64().unwrap_or(0)).unwrap_or(0));
            match status {
                "ok" => {
                    let stored = r["samples"]
                        .as_i64()
                        .or_else(|| r["records"].as_i64())
                        .unwrap_or(0);
                    let detail = if kind == "workout" {
                        let start = r["start"]
                            .as_str()
                            .unwrap_or("")
                            .trim_start_matches("ble-")
                            .get(..16)
                            .unwrap_or("")
                            .replace('T', " ");
                        format!(
                            "{start} UTC · {:.1} km · {} min",
                            r["distance_m"].as_f64().unwrap_or(0.0) / 1000.0,
                            r["duration_s"].as_i64().unwrap_or(0) / 60,
                        )
                    } else {
                        dates_detail(r)
                    };
                    let stored = if kind == "workout" { 1 } else { stored };
                    if stored > 0 {
                        entries.push(store::SyncLogEntry {
                            ts: now.clone(),
                            source: self.source.clone(),
                            kind: kind.to_string(),
                            status: "ok".to_string(),
                            stored,
                            detail,
                        });
                    }
                }
                "crc_error" | "store_error" | "data_error" | "timeout" => {
                    entries.push(store::SyncLogEntry {
                        ts: now.clone(),
                        source: self.source.clone(),
                        kind: kind.to_string(),
                        status: status.to_string(),
                        stored: 0,
                        detail: r["error"].as_str().unwrap_or("").to_string(),
                    });
                }
                // no_data / duplicate / behind_window: nothing was imported
                _ => {}
            }
        }
        if entries.is_empty() && self.authenticated != Some(true) {
            entries.push(store::SyncLogEntry {
                ts: now,
                source: self.source.clone(),
                kind: "session".to_string(),
                status: "error".to_string(),
                stored: 0,
                detail: format!("phase={:?} device={:?}", self.phase, self.device_name),
            });
        }
        if entries.is_empty() {
            return;
        }
        if let Err(e) = store::append_sync_log(&self.state.pool, &self.source, &entries).await {
            tracing::error!("BLE session: sync log write failed: {e}");
        }
    }
}

/// Detail string for fetch results carrying a `dates` array (activity, HRV):
/// the days covered, truncated when a backfill touches many at once.
fn dates_detail(r: &serde_json::Value) -> String {
    let dates: Vec<&str> = r["dates"]
        .as_array()
        .map(|a| a.iter().filter_map(|d| d.as_str()).collect())
        .unwrap_or_default();
    if dates.len() > 3 {
        format!("{} … +{} days", dates[..2].join(", "), dates.len() - 2)
    } else {
        dates.join(", ")
    }
}

fn auth_variant(data: &[u8]) -> &'static str {
    if data.len() >= 3 && data[2] == 0x03 {
        "zeppos3"
    } else {
        "legacy"
    }
}

/// All notify/indicate characteristics under the Huami FEE0 service.
fn subscribable_fee0_characteristics(services: &[ServiceInfo]) -> Vec<String> {
    services
        .iter()
        .filter(|s| s.uuid.to_lowercase().contains("fee0"))
        .flat_map(|s| &s.characteristics)
        .filter(|c: &&CharacteristicInfo| c.notify || c.indicate)
        .map(|c| c.uuid.clone())
        .collect()
}

/// Parse a service-list response: `{0x04, u16 LE count, per service: u16 LE endpoint, u8 encrypted}`.
fn parse_service_list(payload: &[u8]) -> Option<Vec<(u16, u8)>> {
    if payload.len() < 3 {
        return None;
    }
    let count = u16::from_le_bytes([payload[1], payload[2]]) as usize;
    if payload.len() < 3 + count * 3 {
        return None;
    }
    Some(
        (0..count)
            .map(|i| {
                let o = 3 + i * 3;
                (
                    u16::from_le_bytes([payload[o], payload[o + 1]]),
                    payload[o + 2],
                )
            })
            .collect(),
    )
}

/// Current local UTC offset in quarter-hours (the fetch request's tz byte).
fn local_tz_quarter_hours() -> i8 {
    let offset_secs = chrono::Local::now().offset().local_minus_utc();
    i8::try_from(offset_secs / 900).unwrap_or(0)
}

fn hex(bytes: &[u8]) -> String {
    use std::fmt::Write as _;
    bytes.iter().fold(String::new(), |mut out, b| {
        let _ = write!(out, "{b:02x}");
        out
    })
}
