mod common;

use std::time::Duration;

use common::TestApp;
use futures_util::{SinkExt, StreamExt};
use serde_json::{Value, json};
use tokio::net::TcpStream;
use tokio_tungstenite::tungstenite::Message as WsMessage;
use tokio_tungstenite::{MaybeTlsStream, WebSocketStream, connect_async};

const WATCH_MAC: &str = "AA:BB:CC:DD:EE:FF";
const NOTIFY_CHAR: &str = "00000017-0000-1000-8000-00805f9b34fb";

async fn send_evt(ws: &mut WebSocketStream<MaybeTlsStream<TcpStream>>, evt: Value) {
    ws.send(WsMessage::Text(evt.to_string().into()))
        .await
        .expect("send event");
}

/// Receive the next backend command frame as JSON, failing on timeout.
async fn recv_cmd(ws: &mut WebSocketStream<MaybeTlsStream<TcpStream>>) -> Value {
    let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
    loop {
        let remaining = deadline
            .checked_duration_since(tokio::time::Instant::now())
            .unwrap_or(Duration::from_secs(1));
        let msg = tokio::time::timeout(remaining, ws.next())
            .await
            .unwrap_or_else(|_| panic!("timed out waiting for backend command"))
            .expect("ws stream ended while waiting for command")
            .expect("ws error while waiting for command");
        match msg {
            WsMessage::Text(text) => {
                let v: Value = serde_json::from_str(text.as_str()).expect("valid json command");
                assert_eq!(v["t"], "cmd", "expected a command frame, got {v}");
                return v;
            }
            WsMessage::Close(_) => panic!("connection closed while waiting for command"),
            _ => continue,
        }
    }
}

#[tokio::test]
async fn ble_status_reports_disabled_by_default() {
    let app = TestApp::spawn().await;
    let res = app.get("/ble/status").await;
    assert_eq!(res.status(), 200);
    let body: Value = res.json().await.unwrap();
    assert_eq!(body["enabled"], false);
}

#[tokio::test]
async fn ble_ws_returns_404_when_disabled() {
    let app = TestApp::spawn().await;
    let err = connect_async(
        format!("{}/ble/ws?token={}", app.base_url, app.token).replacen("http", "ws", 1),
    )
    .await;
    assert!(err.is_err(), "expected handshake failure when BLE disabled");
}

#[tokio::test]
async fn ble_ws_rejects_missing_and_bad_tokens() {
    let tmp = tempfile::tempdir().unwrap();
    let dir = tmp.path().to_path_buf();
    let app = TestApp::spawn_custom(move |c| {
        c.ble_enabled = true;
        c.ble_sessions_dir = Some(dir);
    })
    .await;

    let no_token = connect_async(format!("{}/ble/ws", app.base_url)).await;
    assert!(no_token.is_err(), "missing token must be refused");

    let bad = connect_async(format!("{}/ble/ws?token=not-a-jwt", app.base_url)).await;
    assert!(bad.is_err(), "invalid token must be refused");
}

#[tokio::test]
async fn ble_relay_autopilot_runs_full_phase1_session() {
    let tmp = tempfile::tempdir().unwrap();
    let sessions_dir = tmp.path().join("sessions");
    let dir_for_config = sessions_dir.clone();
    let app = TestApp::spawn_custom(move |c| {
        c.ble_enabled = true;
        c.ble_watch_name = "TestWatch".to_string();
        c.ble_sessions_dir = Some(dir_for_config);
        c.ble_session_timeout_secs = 30;
    })
    .await;

    let (mut ws, _resp) = connect_async(
        format!("{}/ble/ws?token={}", app.base_url, app.token).replacen("http", "ws", 1),
    )
    .await
    .expect("ws connect");

    // hello -> scan_start
    send_evt(
        &mut ws,
        json!({"t":"evt","k":"hello","platform":"integration-test"}),
    )
    .await;
    let scan = recv_cmd(&mut ws).await;
    assert_eq!(scan["k"], "scan_start");
    assert_eq!(scan["name_filter"], "TestWatch");

    // scan result matching the filter -> connect
    send_evt(
        &mut ws,
        json!({"t":"evt","k":"scan_result","mac":WATCH_MAC,"name":"Amazfit TestWatch 1","rssi":-55}),
    ).await;
    let connect = recv_cmd(&mut ws).await;
    assert_eq!(connect["k"], "connect");
    assert_eq!(connect["mac"], WATCH_MAC);
    let connect_id = connect["id"].as_u64().unwrap();

    // a non-matching scan result must not trigger a second connect
    send_evt(
        &mut ws,
        json!({"t":"evt","k":"scan_result","mac":"11:22:33:44:55:66","name":"Some Headphones","rssi":-70}),
    ).await;

    // connect ack + connected -> request_mtu
    send_evt(
        &mut ws,
        json!({"t":"evt","k":"cmd_result","id":connect_id,"ok":true}),
    )
    .await;
    send_evt(&mut ws, json!({"t":"evt","k":"connected","mtu":23})).await;
    let mtu_cmd = recv_cmd(&mut ws).await;
    assert_eq!(mtu_cmd["k"], "request_mtu");
    assert_eq!(mtu_cmd["mtu"], 247);
    send_evt(
        &mut ws,
        json!({"t":"evt","k":"cmd_result","id":mtu_cmd["id"],"ok":true}),
    )
    .await;
    send_evt(&mut ws, json!({"t":"evt","k":"mtu","mtu":247})).await;

    // services with a FEE0 notify characteristic -> subscribe
    send_evt(
        &mut ws,
        json!({"t":"evt","k":"services","services":[{"uuid":"0000fee0-0000-1000-8000-00805f9b34fb","characteristics":[
            {"uuid":NOTIFY_CHAR,"notify":true},
            {"uuid":"0000fee5-0000-1000-8000-00805f9b34fb","notify":false,"read":true}
        ]}]}),
    )
    .await;
    let sub = recv_cmd(&mut ws).await;
    assert_eq!(sub["k"], "subscribe");
    assert_eq!(sub["char_uuid"], NOTIFY_CHAR);
    send_evt(
        &mut ws,
        json!({"t":"evt","k":"cmd_result","id":sub["id"],"ok":true}),
    )
    .await;

    // notifications are counted
    send_evt(
        &mut ws,
        json!({"t":"evt","k":"notify_batch","items":[{"char_uuid":NOTIFY_CHAR,"data":"AQIDBA=="}]}),
    )
    .await;

    // device disconnects -> shutdown
    send_evt(
        &mut ws,
        json!({"t":"evt","k":"disconnected","reason":"test-complete"}),
    )
    .await;
    let shutdown = recv_cmd(&mut ws).await;
    assert_eq!(shutdown["k"], "shutdown");
    assert_eq!(shutdown["reason"], "device_disconnected");

    // server closes the socket after the shutdown grace period
    let close = tokio::time::timeout(Duration::from_secs(10), async {
        while let Some(msg) = ws.next().await {
            if matches!(msg, Ok(WsMessage::Close(_)) | Err(_)) {
                return;
            }
        }
    })
    .await;
    assert!(close.is_ok(), "server should close the ws after shutdown");
    drop(ws);

    // session recording exists and contains both directions
    let mut files: Vec<_> = std::fs::read_dir(&sessions_dir)
        .expect("sessions dir")
        .flatten()
        .map(|e| e.path())
        .collect();
    assert_eq!(files.len(), 1, "exactly one session file expected");
    let content = std::fs::read_to_string(files.pop().unwrap()).unwrap();
    assert!(content.contains("\"dir\":\"s2c\""));
    assert!(content.contains("\"dir\":\"c2s\""));
    assert!(content.contains("scan_start"));
    assert!(content.contains(WATCH_MAC));
    assert!(content.contains("AQIDBA=="));
    assert!(content.contains("session_end"));
}

#[tokio::test]
async fn ble_connect_failure_ends_session_with_shutdown() {
    let tmp = tempfile::tempdir().unwrap();
    let dir = tmp.path().to_path_buf();
    let app = TestApp::spawn_custom(move |c| {
        c.ble_enabled = true;
        c.ble_watch_name = "TestWatch".to_string();
        c.ble_sessions_dir = Some(dir);
    })
    .await;

    let (mut ws, _resp) = connect_async(
        format!("{}/ble/ws?token={}", app.base_url, app.token).replacen("http", "ws", 1),
    )
    .await
    .expect("ws connect");

    send_evt(&mut ws, json!({"t":"evt","k":"hello"})).await;
    let scan = recv_cmd(&mut ws).await;
    assert_eq!(scan["k"], "scan_start");

    send_evt(
        &mut ws,
        json!({"t":"evt","k":"scan_result","mac":WATCH_MAC,"name":"TestWatch","rssi":-55}),
    )
    .await;
    let connect = recv_cmd(&mut ws).await;
    assert_eq!(connect["k"], "connect");

    send_evt(
        &mut ws,
        json!({"t":"evt","k":"cmd_result","id":connect["id"],"ok":false,"error":"gatt status 133"}),
    )
    .await;

    let shutdown = recv_cmd(&mut ws).await;
    assert_eq!(shutdown["k"], "shutdown");
    assert_eq!(shutdown["reason"], "connect_failed");
}

// ── Phase 2: auth handshake + chunked service list ──────────────────────────

use mont::ble::auth::{AuthSession, aes_ecb_block};

const AUTH_CHAR: &str = "00000001-0000-3512-2118-0009af100700";
const CHUNKED_WRITE_CHAR: &str = "00000016-0000-3512-2118-0009af100700";
const CHUNKED_READ_CHAR: &str = "00000017-0000-3512-2118-0009af100700";
const TEST_AUTH_KEY: [u8; 16] = [
    0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f,
];

async fn recv_write(
    ws: &mut WebSocketStream<MaybeTlsStream<TcpStream>>,
    char_prefix: &str,
) -> Vec<u8> {
    loop {
        let cmd = recv_cmd(ws).await;
        assert_eq!(
            cmd["k"], "write",
            "expected a write to {char_prefix}, got {cmd}"
        );
        let char_uuid = cmd["char_uuid"].as_str().expect("char uuid");
        if char_uuid.starts_with(char_prefix) {
            use base64::Engine as _;
            return base64::engine::general_purpose::STANDARD
                .decode(cmd["data"].as_str().expect("data"))
                .expect("base64 data");
        }
        panic!("write to unexpected characteristic {char_uuid}: {cmd}");
    }
}

async fn ack_cmd(ws: &mut WebSocketStream<MaybeTlsStream<TcpStream>>, cmd: &Value) {
    send_evt(
        ws,
        json!({"t":"evt","k":"cmd_result","id":cmd["id"],"ok":true}),
    )
    .await;
}

/// A minimal single-chunk chunked-protocol frame carrying `payload` on `endpoint`.
fn chunk_frame(endpoint: u16, payload: &[u8], handle: u8) -> Vec<u8> {
    let mut f = vec![0x03, 0x07, 0x00, handle, 0x00];
    f.extend_from_slice(&(payload.len() as u32).to_le_bytes());
    f.extend_from_slice(&endpoint.to_le_bytes());
    f.extend_from_slice(payload);
    f
}

#[tokio::test]
async fn ble_relay_authenticates_and_discovers_services() {
    let tmp = tempfile::tempdir().unwrap();
    let sessions_dir = tmp.path().join("sessions");
    let dir_for_config = sessions_dir.clone();
    let app = TestApp::spawn_custom(move |c| {
        c.ble_enabled = true;
        c.ble_watch_name = "TestWatch".to_string();
        c.ble_auth_key = Some("000102030405060708090a0b0c0d0e0f".to_string());
        c.ble_settle_secs = 1;
        c.ble_sessions_dir = Some(dir_for_config);
        c.ble_session_timeout_secs = 30;
    })
    .await;

    let (mut ws, _resp) = connect_async(
        format!("{}/ble/ws?token={}", app.base_url, app.token).replacen("http", "ws", 1),
    )
    .await
    .expect("ws connect");

    // hello -> scan -> connect -> connected -> mtu
    send_evt(&mut ws, json!({"t":"evt","k":"hello"})).await;
    let scan = recv_cmd(&mut ws).await;
    assert_eq!(scan["k"], "scan_start");
    send_evt(
        &mut ws,
        json!({"t":"evt","k":"scan_result","mac":WATCH_MAC,"name":"TestWatch","rssi":-55}),
    )
    .await;
    let connect = recv_cmd(&mut ws).await;
    assert_eq!(connect["k"], "connect");
    ack_cmd(&mut ws, &connect).await;
    send_evt(&mut ws, json!({"t":"evt","k":"connected","mtu":23})).await;
    let mtu_cmd = recv_cmd(&mut ws).await;
    assert_eq!(mtu_cmd["k"], "request_mtu");
    ack_cmd(&mut ws, &mtu_cmd).await;
    send_evt(&mut ws, json!({"t":"evt","k":"mtu","mtu":247})).await;

    // services: FEE0 with auth + chunked chars -> 3 subscribes
    send_evt(
        &mut ws,
        json!({"t":"evt","k":"services","services":[{"uuid":"0000fee0-0000-1000-8000-00805f9b34fb","characteristics":[
            {"uuid":AUTH_CHAR,"indicate":true,"write":true},
            {"uuid":CHUNKED_WRITE_CHAR,"write_without_response":true},
            {"uuid":CHUNKED_READ_CHAR,"notify":true}
        ]}]}),
    )
    .await;
    // only the auth (indicate) and read (notify) chars are subscribable — the
    // write-only 0x0016 is skipped by the driver
    for _ in 0..2 {
        let sub = recv_cmd(&mut ws).await;
        assert_eq!(sub["k"], "subscribe");
        ack_cmd(&mut ws, &sub).await;
    }

    // all subscribes acked -> auth start write on the auth characteristic
    let auth_start = recv_write(&mut ws, "00000001-").await;
    assert_eq!(auth_start, AuthSession::start_request());

    // watch challenges (ZeppOS 3.x variant) -> driver replies with encrypted key
    send_evt(
        &mut ws,
        json!({"t":"evt","k":"notify_batch","items":[{"char_uuid":AUTH_CHAR,"data":base64_of(&[0x10, 0x01, 0x03, 0x05])}]}),
    )
    .await; // 10 01 03 05
    let key_reply = recv_write(&mut ws, "00000001-").await;
    assert_eq!(&key_reply[..2], &[0x03, 0x00]);
    assert_eq!(
        &key_reply[2..],
        &aes_ecb_block(&TEST_AUTH_KEY, &[0u8; 16])[..]
    );

    // watch accepts -> driver is ready and asks for the service list (chunked)
    send_evt(
        &mut ws,
        json!({"t":"evt","k":"notify_batch","items":[{"char_uuid":AUTH_CHAR,"data":base64_of(&[0x10, 0x03, 0x05])}]}),
    )
    .await; // 10 03 05
    let list_request = recv_write(&mut ws, "00000016-").await;
    // single chunk at mtu 247: 03 07 00 01 00 | len=1 LE32 | endpoint 0x0000 | 0x03
    assert_eq!(
        list_request,
        vec![
            0x03, 0x07, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03
        ]
    );

    // watch answers with a 2-service list (needs-ack) -> driver sends the chunk ack
    let payload = [0x04u8, 0x02, 0x00, 0x82, 0x00, 0x01, 0x00, 0x4b, 0x00];
    send_evt(
        &mut ws,
        json!({"t":"evt","k":"notify_batch","items":[
            {"char_uuid":CHUNKED_READ_CHAR,"data":base64_of(&chunk_frame(0x0000, &payload, 5))}
        ]}),
    )
    .await;
    let ack = recv_write(&mut ws, "00000017-").await;
    assert_eq!(ack, vec![0x04, 0x00, 0x05, 0x01, 0x00]);

    // settle (1s) -> release + shutdown
    let _disconnect = recv_cmd(&mut ws).await; // disconnect_device
    let shutdown = recv_cmd(&mut ws).await;
    assert_eq!(shutdown["k"], "shutdown");
    assert_eq!(shutdown["reason"], "session_complete");

    let files: Vec<_> = std::fs::read_dir(&sessions_dir)
        .unwrap()
        .flatten()
        .map(|e| e.path())
        .collect();
    assert_eq!(files.len(), 1);
    // The driver writes the session_end summary after the shutdown grace
    // period; poll for it.
    let mut content = String::new();
    for _ in 0..50 {
        content = std::fs::read_to_string(&files[0]).unwrap();
        if content.contains("\"event\":\"session_end\"") {
            break;
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    assert!(content.contains("\"event\":\"session_end\""));
    assert!(content.contains("\"event\":\"authenticated\""));
    assert!(content.contains("\"event\":\"service_list\""));
    assert!(content.contains("\"authenticated\":true"));
}

/// base64 helper usable in test data literals.
fn base64_of(data: &[u8]) -> String {
    use base64::Engine as _;
    base64::engine::general_purpose::STANDARD.encode(data)
}

// ── Phase 3: health fetch flow with storage ─────────────────────────────────

use mont::ble::codec::ChunkedDecoder;

/// Read the next write command and decode it as a chunked frame.
async fn recv_chunked_write(ws: &mut WebSocketStream<MaybeTlsStream<TcpStream>>) -> (u16, Vec<u8>) {
    use base64::Engine as _;
    loop {
        let cmd = recv_cmd(ws).await;
        assert_eq!(cmd["k"], "write", "expected a write, got {cmd}");
        let char_uuid = cmd["char_uuid"].as_str().expect("char uuid").to_string();
        if !char_uuid.starts_with("00000016-") && !char_uuid.starts_with("00000017-") {
            panic!("write to unexpected characteristic {char_uuid}");
        }
        let data = base64::engine::general_purpose::STANDARD
            .decode(cmd["data"].as_str().expect("data"))
            .expect("base64 data");
        let mut dec = ChunkedDecoder::new();
        if let Ok(Some(msg)) = dec.decode(&data) {
            return (msg.endpoint, msg.payload);
        }
    }
}

/// Send a chunked frame from the "watch" as a notification.
async fn send_chunked_notify(
    ws: &mut WebSocketStream<MaybeTlsStream<TcpStream>>,
    endpoint: u16,
    payload: &[u8],
    handle: u8,
) {
    let frame = chunk_frame(endpoint, payload, handle);
    send_evt(
        ws,
        json!({"t":"evt","k":"notify_batch","items":[
            {"char_uuid":"00000017-0000-3512-2118-0009af100700","data":base64_of(&frame)}
        ]}),
    )
    .await;
}

#[tokio::test]
async fn ble_relay_fetches_and_stores_health_data() {
    let tmp = tempfile::tempdir().unwrap();
    let sessions_dir = tmp.path().join("sessions");
    let dir_for_config = sessions_dir.clone();
    let app = TestApp::spawn_custom(move |c| {
        c.ble_enabled = true;
        c.ble_watch_name = "TestWatch".to_string();
        c.ble_auth_key = Some("000102030405060708090a0b0c0d0e0f".to_string());
        c.ble_settle_secs = 1;
        c.ble_fetch_enabled = true;
        c.ble_fetch_lookback_days = 30;
        c.ble_sessions_dir = Some(dir_for_config);
        c.ble_session_timeout_secs = 60;
    })
    .await;

    let (mut ws, _resp) = connect_async(
        format!("{}/ble/ws?token={}", app.base_url, app.token).replacen("http", "ws", 1),
    )
    .await
    .expect("ws connect");

    // connect flow (same as the phase-2 test, condensed)
    send_evt(&mut ws, json!({"t":"evt","k":"hello"})).await;
    let scan = recv_cmd(&mut ws).await;
    assert_eq!(scan["k"], "scan_start");
    send_evt(
        &mut ws,
        json!({"t":"evt","k":"scan_result","mac":WATCH_MAC,"name":"TestWatch","rssi":-55}),
    )
    .await;
    let connect = recv_cmd(&mut ws).await;
    ack_cmd(&mut ws, &connect).await;
    send_evt(&mut ws, json!({"t":"evt","k":"connected","mtu":23})).await;
    let mtu_cmd = recv_cmd(&mut ws).await;
    ack_cmd(&mut ws, &mtu_cmd).await;
    send_evt(&mut ws, json!({"t":"evt","k":"mtu","mtu":247})).await;
    send_evt(
        &mut ws,
        json!({"t":"evt","k":"services","services":[{"uuid":"0000fee0-0000-1000-8000-00805f9b34fb","characteristics":[
            {"uuid":AUTH_CHAR,"indicate":true,"write":true},
            {"uuid":CHUNKED_WRITE_CHAR,"write_without_response":true},
            {"uuid":CHUNKED_READ_CHAR,"notify":true},
            {"uuid":"00000005-0000-3512-2118-0009af100700","notify":true}
        ]}]}),
    )
    .await;
    for _ in 0..3 {
        let sub = recv_cmd(&mut ws).await;
        assert_eq!(sub["k"], "subscribe");
        ack_cmd(&mut ws, &sub).await;
    }

    // auth handshake
    let auth_start = recv_write(&mut ws, "00000001-").await;
    assert_eq!(auth_start, AuthSession::start_request());
    send_evt(
        &mut ws,
        json!({"t":"evt","k":"notify_batch","items":[
            {"char_uuid":AUTH_CHAR,"data":base64_of(&[0x10, 0x01, 0x03, 0x05])}
        ]}),
    )
    .await;
    let _key_reply = recv_write(&mut ws, "00000001-").await;
    send_evt(
        &mut ws,
        json!({"t":"evt","k":"notify_batch","items":[
            {"char_uuid":AUTH_CHAR,"data":base64_of(&[0x10, 0x03, 0x05])}
        ]}),
    )
    .await;

    // first write after auth: service list request
    let (ep, payload) = recv_chunked_write(&mut ws).await;
    assert_eq!(ep, 0x0000);
    assert_eq!(payload, vec![0x03]);

    // ── run the four fetch types with a fake watch ──
    let mut handle = 9u8;

    // resting HR (0x3a): one 6-byte record
    let rest_epoch: i32 = 1_700_000_000;
    let mut rest_record = Vec::new();
    rest_record.extend_from_slice(&rest_epoch.to_le_bytes());
    rest_record.extend_from_slice(&[4, 52]);
    run_fetch_type(
        &mut ws,
        0x3a,
        start_response_payload(6, rest_epoch),
        Some(rest_record.clone()),
        &mut handle,
        0x09,
    )
    .await;

    // max HR (0x3d): no data
    run_fetch_type(
        &mut ws,
        0x3d,
        start_response_payload(0, rest_epoch),
        None,
        &mut handle,
        0x09,
    )
    .await;

    // HRV (0x49): two 6-byte records on consecutive days
    let mut hrv_payload = Vec::new();
    for (epoch, value) in [(rest_epoch, 40u8), (rest_epoch + 86_400, 55u8)] {
        hrv_payload.extend_from_slice(&epoch.to_le_bytes());
        hrv_payload.extend_from_slice(&[1, value]);
    }
    run_fetch_type(
        &mut ws,
        0x49,
        start_response_payload(12, rest_epoch),
        Some(hrv_payload.clone()),
        &mut handle,
        0x09,
    )
    .await;

    // activity (0x01): 3 one-minute samples on 2023-11-14
    let act_start: i32 = (chrono::Utc::now().timestamp() - 3600) as i32; // one hour ago
    let mut act_payload = Vec::new();
    for i in 0..3u8 {
        act_payload.extend_from_slice(&[115, 20, i * 30, 60 + i, 0, 0, 0, 0]);
    }
    run_fetch_type(
        &mut ws,
        0x01,
        start_response_payload(24, act_start),
        Some(act_payload.clone()),
        &mut handle,
        0x09,
    )
    .await;

    // activity catches up (start+3min is in the past) → second round → no data
    run_fetch_type(
        &mut ws,
        0x01,
        start_response_payload(0, act_start),
        None,
        &mut handle,
        0x09,
    )
    .await;

    // workout details (0x06): no data → queue empty → settle
    run_fetch_type(
        &mut ws,
        0x06,
        start_response_payload(0, act_start),
        None,
        &mut handle,
        0x01,
    )
    .await;

    // all fetches done → settle → release
    // tolerate the release command(s) and transport chunk-acks before shutdown
    loop {
        let cmd = recv_cmd(&mut ws).await;
        if cmd["k"] == "shutdown" {
            assert_eq!(cmd["reason"], "session_complete");
            break;
        }
        assert!(
            cmd["k"] == "disconnect_device" || cmd["k"] == "write",
            "unexpected frame before shutdown: {cmd}"
        );
    }

    // ── DB assertions ──
    let (samples,): (i64,) = sqlx::query_as("SELECT COUNT(*) FROM activity_samples")
        .fetch_one(&app.pool)
        .await
        .unwrap();
    assert_eq!(samples, 3);
    let (avg, min, max, steps): (Option<f64>, Option<i64>, Option<i64>, Option<i64>) = sqlx::query_as(
        "SELECT AVG(hr), MIN(hr), MAX(hr), SUM(steps) FROM activity_samples WHERE hr > 0 AND hr < 255",
    )
    .fetch_one(&app.pool)
    .await
    .unwrap();
    assert_eq!((min, max, steps), (Some(60), Some(62), Some(90)));
    assert_eq!(avg, Some(61.0));
    let (hrv_count,): (i64,) = sqlx::query_as("SELECT COUNT(*) FROM hrv_samples")
        .fetch_one(&app.pool)
        .await
        .unwrap();
    assert_eq!(hrv_count, 2);
    let (resting,): (Option<i64>,) =
        sqlx::query_as("SELECT resting_hr FROM daily_hr_marks WHERE date = date(?, 'unixepoch')")
            .bind(rest_epoch)
            .fetch_one(&app.pool)
            .await
            .unwrap();
    assert_eq!(resting, Some(52));
    let (daily_count,): (i64,) = sqlx::query_as(
        "SELECT COUNT(*) FROM daily_health WHERE date IN ('2023-11-14', '2023-11-15')",
    )
    .fetch_one(&app.pool)
    .await
    .unwrap();
    assert!(daily_count >= 1, "daily_health rows should exist");
    // today's activity lands in today's daily aggregate
    let (today_steps,): (Option<i64>,) =
        sqlx::query_as("SELECT steps FROM daily_health WHERE date = DATE('now')")
            .fetch_one(&app.pool)
            .await
            .unwrap();
    assert_eq!(today_steps, Some(90));
    let (synced_types,): (i64,) =
        sqlx::query_as("SELECT COUNT(DISTINCT data_type) FROM watch_sync_state")
            .fetch_one(&app.pool)
            .await
            .unwrap();
    // resting, HRV, activity + summaries "no data" (max HR had no data at all)
    assert_eq!(synced_types, 4);
}

/// CRC32 (IEEE) computed via the backend's crate dependency.
fn crc32(data: &[u8]) -> u32 {
    crc32fast::hash(data)
}

/// Watch-style start-date response payload: `{0x10,0x01,0x01, len, ts…}`.
fn start_response_payload(len: u32, epoch: i32) -> Vec<u8> {
    use chrono::{Datelike, TimeZone, Timelike, Utc};
    let dt = Utc.timestamp_opt(i64::from(epoch), 0).single().unwrap();
    let mut p = vec![0x10, 0x01, 0x01];
    p.extend_from_slice(&len.to_le_bytes());
    p.extend_from_slice(&(dt.year() as u16).to_le_bytes());
    p.push(dt.month() as u8);
    p.push(dt.day() as u8);
    p.push(dt.hour() as u8);
    p.push(dt.minute() as u8);
    p.push(dt.second() as u8);
    p.push(4);
    p
}

/// Drive one fetch type: read the request, answer with `start_resp`, stream
/// `data` (if any) on 0x0005, send the end marker with CRC, verify the ack
/// (`0x09` keep for health, `0x01` mark-sent for workouts), and close with the
/// ack reply.
async fn run_fetch_type(
    ws: &mut WebSocketStream<MaybeTlsStream<TcpStream>>,
    type_byte: u8,
    start_resp: Vec<u8>,
    data: Option<Vec<u8>>,
    handle: &mut u8,
    ack: u8,
) {
    // fetch request
    let (ep, payload) = recv_chunked_write(ws).await;
    assert_eq!(ep, 0x004b);
    assert_eq!(payload[0], 0x01, "fetch request for {type_byte:#04x}");
    assert_eq!(payload[1], type_byte);

    // start-date response
    *handle += 1;
    send_chunked_notify(ws, 0x004b, &start_resp, *handle).await;

    // the driver starts the transfer with {0x02} (unless there is no data)
    let no_data = start_resp[3..7] == [0u8, 0, 0, 0][..];
    if !no_data {
        let (ep, payload) = recv_chunked_write(ws).await;
        assert_eq!(ep, 0x004b);
        assert_eq!(payload, vec![0x02]);
    }

    if let Some(data) = data {
        let mut packet = vec![1u8];
        packet.extend_from_slice(&data);
        send_evt(
            ws,
            json!({"t":"evt","k":"notify_batch","items":[
                {"char_uuid":"00000005-0000-3512-2118-0009af100700","data":base64_of(&packet)}
            ]}),
        )
        .await;
        // end marker with CRC over the payload
        *handle += 1;
        let crc = crc32(&data);
        let mut end = vec![0x10, 0x02, 0x01];
        end.extend_from_slice(&crc.to_le_bytes());
        send_chunked_notify(ws, 0x004b, &end, *handle).await;
    }

    // ack (keep-data for health, mark-sent for workouts)
    let (ep, payload) = recv_chunked_write(ws).await;
    assert_eq!(ep, 0x004b);
    assert_eq!(payload, vec![0x03, ack]);

    // ack reply closes the operation
    *handle += 1;
    send_chunked_notify(ws, 0x004b, &[0x10, 0x03, 0x01], *handle).await;
}

#[tokio::test]
async fn ble_relay_imports_workout_with_route() {
    let _tmp = tempfile::tempdir().unwrap();
    let sessions_dir = std::path::PathBuf::from("/tmp/ble-test-sessions");
    let dir_for_config = sessions_dir.clone();
    let app = TestApp::spawn_custom(move |c| {
        c.ble_enabled = true;
        c.ble_watch_name = "TestWatch".to_string();
        c.ble_auth_key = Some("000102030405060708090a0b0c0d0e0f".to_string());
        c.ble_settle_secs = 1;
        c.ble_fetch_enabled = true;
        c.ble_fetch_lookback_days = 30;
        c.ble_sessions_dir = Some(dir_for_config);
        c.ble_session_timeout_secs = 60;
    })
    .await;

    let (mut ws, _resp) = connect_async(
        format!("{}/ble/ws?token={}", app.base_url, app.token).replacen("http", "ws", 1),
    )
    .await
    .expect("ws connect");

    // connect + auth (same as the phase-3 test)
    send_evt(&mut ws, json!({"t":"evt","k":"hello"})).await;
    let scan = recv_cmd(&mut ws).await;
    assert_eq!(scan["k"], "scan_start");
    send_evt(
        &mut ws,
        json!({"t":"evt","k":"scan_result","mac":WATCH_MAC,"name":"TestWatch","rssi":-55}),
    )
    .await;
    let connect = recv_cmd(&mut ws).await;
    ack_cmd(&mut ws, &connect).await;
    send_evt(&mut ws, json!({"t":"evt","k":"connected","mtu":23})).await;
    let mtu_cmd = recv_cmd(&mut ws).await;
    ack_cmd(&mut ws, &mtu_cmd).await;
    send_evt(&mut ws, json!({"t":"evt","k":"mtu","mtu":247})).await;
    send_evt(
        &mut ws,
        json!({"t":"evt","k":"services","services":[{"uuid":"0000fee0-0000-1000-8000-00805f9b34fb","characteristics":[
            {"uuid":AUTH_CHAR,"indicate":true,"write":true},
            {"uuid":CHUNKED_WRITE_CHAR,"write_without_response":true},
            {"uuid":CHUNKED_READ_CHAR,"notify":true},
            {"uuid":"00000005-0000-3512-2118-0009af100700","notify":true}
        ]}]}),
    )
    .await;
    for _ in 0..3 {
        let sub = recv_cmd(&mut ws).await;
        assert_eq!(sub["k"], "subscribe");
        ack_cmd(&mut ws, &sub).await;
    }
    let auth_start = recv_write(&mut ws, "00000001-").await;
    assert_eq!(auth_start, AuthSession::start_request());
    send_evt(
        &mut ws,
        json!({"t":"evt","k":"notify_batch","items":[
            {"char_uuid":AUTH_CHAR,"data":base64_of(&[0x10, 0x01, 0x03, 0x05])}
        ]}),
    )
    .await;
    let _key_reply = recv_write(&mut ws, "00000001-").await;
    send_evt(
        &mut ws,
        json!({"t":"evt","k":"notify_batch","items":[
            {"char_uuid":AUTH_CHAR,"data":base64_of(&[0x10, 0x03, 0x05])}
        ]}),
    )
    .await;

    // skip the service-list request, then answer every health fetch with
    // "no data" so we get to the workout phase quickly
    let _service_list = recv_chunked_write(&mut ws).await;

    let mut handle = 20u8;
    for type_byte in [0x3au8, 0x3d, 0x49, 0x01] {
        let (ep, payload) = recv_chunked_write(&mut ws).await;
        assert_eq!((ep, payload[0], payload[1]), (0x004b, 0x01, type_byte));
        handle += 1;
        send_chunked_notify(
            &mut ws,
            0x004b,
            &[
                [0x10u8, 0x01, 0x01].as_slice(),
                &0i32.to_le_bytes(),
                &[0; 8],
            ]
            .concat(),
            handle,
        )
        .await;
        let (_ep, payload) = recv_chunked_write(&mut ws).await;
        assert_eq!(payload, vec![0x03, 0x09]);
        handle += 1;
        send_chunked_notify(&mut ws, 0x004b, &[0x10, 0x03, 0x01], handle).await;
    }

    // ── workout details (0x06): the workout importer; minimal psmh TLV with
    // 2 GPS points, one minute apart ──
    let start_epoch = chrono::Utc::now().timestamp() - 1800;
    let (ep, payload) = recv_chunked_write(&mut ws).await;
    assert_eq!((ep, payload[0], payload[1]), (0x004b, 0x01, 0x06));
    let ts_ms = start_epoch * 1000;
    let lon = 49_110_000i32; // 16.37°
    let lat = 147_600_000i32; // 49.2°
    let mut details = Vec::new();
    details.extend_from_slice(&[1u8, 12, 0, 0, 0, 0]);
    details.extend_from_slice(&ts_ms.to_le_bytes());
    details.extend_from_slice(&[2u8, 20, 0, 0, 0, 0, 0, 0]);
    // (content = 6 unk + lon + lat + 6 unk = 20)
    details.extend_from_slice(&lon.to_le_bytes());
    details.extend_from_slice(&lat.to_le_bytes());
    details.extend_from_slice(&[0u8; 6]);
    // delta: +10s, +0.001° lon, +0.001° lat
    details.extend_from_slice(&[3u8, 8]);
    details.extend_from_slice(&10_000i16.to_le_bytes());
    details.extend_from_slice(&30i16.to_le_bytes());
    details.extend_from_slice(&30i16.to_le_bytes());
    details.extend_from_slice(&2u16.to_le_bytes());
    handle += 1;
    send_chunked_notify(
        &mut ws,
        0x004b,
        &start_response_payload(
            details.len() as u32,
            i32::try_from(start_epoch).unwrap_or(0),
        ),
        handle,
    )
    .await;
    let (_ep, payload) = recv_chunked_write(&mut ws).await;
    assert_eq!(payload, vec![0x02]);
    send_evt(
        &mut ws,
        json!({"t":"evt","k":"notify_batch","items":[
            {"char_uuid":"00000005-0000-3512-2118-0009af100700","data":base64_of(&[[1u8].as_slice(), details.as_slice()].concat())}
        ]}),
    )
    .await;
    let crc = crc32(details.as_slice());
    handle += 1;
    send_chunked_notify(
        &mut ws,
        0x004b,
        &[[0x10u8, 0x02, 0x01].as_slice(), &crc.to_le_bytes()].concat(),
        handle,
    )
    .await;
    let (_ep, payload) = recv_chunked_write(&mut ws).await;
    assert_eq!(payload, vec![0x03, 0x01]);
    handle += 1;
    send_chunked_notify(&mut ws, 0x004b, &[0x10, 0x03, 0x01], handle).await;

    // pointer is behind now → one more details round → no data → settle
    let (ep, payload) = recv_chunked_write(&mut ws).await;
    assert_eq!((ep, payload[0], payload[1]), (0x004b, 0x01, 0x06));
    handle += 1;
    send_chunked_notify(
        &mut ws,
        0x004b,
        &start_response_payload(0, i32::try_from(start_epoch).unwrap_or(0)),
        handle,
    )
    .await;
    let (_ep, payload) = recv_chunked_write(&mut ws).await;
    assert_eq!(payload, vec![0x03, 0x01]);
    handle += 1;
    send_chunked_notify(&mut ws, 0x004b, &[0x10, 0x03, 0x01], handle).await;

    // workout end == now → no more rounds → settle
    loop {
        let cmd = recv_cmd(&mut ws).await;
        if cmd["k"] == "shutdown" {
            assert_eq!(cmd["reason"], "session_complete");
            break;
        }
        assert!(
            cmd["k"] == "disconnect_device" || cmd["k"] == "write",
            "unexpected frame before shutdown: {cmd}"
        );
    }

    // ── DB assertions (values derive from the details payload: 2 points,
    // 10 s apart, no HR TLV) ──
    let (count, duration, distance): (i64, i64, f64) = sqlx::query_as(
        "SELECT COUNT(*), duration_s, distance_m FROM runs WHERE source_file LIKE 'ble-%'",
    )
    .fetch_one(&app.pool)
    .await
    .unwrap();
    assert_eq!(count, 1);
    assert_eq!(duration, 10); // last route point offset
    assert!(
        distance > 0.0 && distance < 100.0,
        "haversine distance: {distance}"
    );
    let (avg, max): (Option<i64>, Option<i64>) =
        sqlx::query_as("SELECT avg_hr, max_hr FROM runs WHERE source_file LIKE 'ble-%'")
            .fetch_one(&app.pool)
            .await
            .unwrap();
    assert_eq!((avg, max), (None, None)); // no HR TLV in the fixture
    let (route,): (String,) =
        sqlx::query_as("SELECT route_json FROM runs WHERE source_file LIKE 'ble-%'")
            .fetch_one(&app.pool)
            .await
            .unwrap();
    let points: Vec<serde_json::Value> = serde_json::from_str(&route).unwrap();
    assert!(points.len() >= 2, "route should have GPS points: {route}");
}
