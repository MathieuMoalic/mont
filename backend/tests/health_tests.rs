mod common;

/// Minimal FIT monitoring file: 2 days of HR + step data + HRV intervals.
///
/// Day 2026-01-15: HR=[62,72,65] → avg=66, min=62, max=72; steps_max=7000
/// Day 2026-01-16: HR=[58,80,70] → avg=69, min=58, max=80; steps_max=10000
/// HRV (seconds): [0.98,1.01,0.97,1.03,0.99] → RMSSD≈43.87ms for day 1
///        and [0.92,0.96,0.94,0.98,0.95] → RMSSD≈33.54ms for day 2
const HEALTH_FIT: &[u8] = &[
    0x0e, 0x10, 0x43, 0x08, 0x6a, 0x00, 0x00, 0x00, 0x2e, 0x46, 0x49, 0x54, 0x70, 0xc9, 0x40,
    0x00, 0x00, 0x37, 0x00, 0x03, 0xfd, 0x04, 0x86, 0x14, 0x01, 0x02, 0x03, 0x04, 0x86, 0x41,
    0x00, 0x00, 0x4e, 0x00, 0x01, 0x00, 0x0a, 0x84, 0x00, 0x80, 0x52, 0xcb, 0x43, 0x3e, 0x00,
    0x00, 0x00, 0x00, 0x00, 0xc0, 0x8a, 0xcb, 0x43, 0x48, 0xb8, 0x0b, 0x00, 0x00, 0x00, 0x40,
    0xfb, 0xcb, 0x43, 0x41, 0x58, 0x1b, 0x00, 0x00, 0x01, 0xd4, 0x03, 0xf2, 0x03, 0xca, 0x03,
    0x06, 0x04, 0xde, 0x03, 0x00, 0x00, 0xa4, 0xcc, 0x43, 0x3a, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x40, 0xdc, 0xcc, 0x43, 0x50, 0xa0, 0x0f, 0x00, 0x00, 0x00, 0xc0, 0x4c, 0xcd, 0x43, 0x46,
    0x10, 0x27, 0x00, 0x00, 0x01, 0x98, 0x03, 0xc0, 0x03, 0xac, 0x03, 0xd4, 0x03, 0xb6, 0x03,
    0xd8, 0x9f,
];

async fn import_health(app: &common::TestApp, data: &[u8]) -> reqwest::Response {
    let part = reqwest::multipart::Part::bytes(data.to_vec())
        .file_name("health.fit")
        .mime_str("application/octet-stream")
        .unwrap();
    let form = reqwest::multipart::Form::new().part("file", part);
    app.client
        .post(app.url("/health/fit"))
        .bearer_auth(&app.token)
        .multipart(form)
        .send()
        .await
        .unwrap()
}

#[tokio::test]
async fn import_health_fit_returns_201() {
    let app = common::TestApp::spawn().await;
    let res = import_health(&app, HEALTH_FIT).await;
    assert_eq!(res.status(), 201);
    let body: serde_json::Value = res.json().await.unwrap();
    assert_eq!(body["imported"], 2);
}

#[tokio::test]
async fn import_health_fit_stores_hr_and_steps() {
    let app = common::TestApp::spawn().await;
    import_health(&app, HEALTH_FIT).await;

    let rows: serde_json::Value = app
        .client
        .get(app.url("/health/daily"))
        .bearer_auth(&app.token)
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();

    let day1 = rows
        .as_array()
        .unwrap()
        .iter()
        .find(|r| r["date"] == "2026-01-15")
        .expect("day1 missing");

    assert_eq!(day1["avg_hr"], 66);
    assert_eq!(day1["min_hr"], 62);
    assert_eq!(day1["max_hr"], 72);
    assert_eq!(day1["steps"], 7000);

    let day2 = rows
        .as_array()
        .unwrap()
        .iter()
        .find(|r| r["date"] == "2026-01-16")
        .expect("day2 missing");

    assert_eq!(day2["avg_hr"], 69);
    assert_eq!(day2["min_hr"], 58);
    assert_eq!(day2["max_hr"], 80);
    assert_eq!(day2["steps"], 10000);
}

#[tokio::test]
async fn import_health_fit_computes_hrv_rmssd() {
    let app = common::TestApp::spawn().await;
    import_health(&app, HEALTH_FIT).await;

    let rows: serde_json::Value = app
        .client
        .get(app.url("/health/daily"))
        .bearer_auth(&app.token)
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();

    let day1 = rows
        .as_array()
        .unwrap()
        .iter()
        .find(|r| r["date"] == "2026-01-15")
        .unwrap();

    let rmssd = day1["hrv_rmssd"].as_f64().expect("hrv_rmssd missing");
    // Expected ≈ 43.87 ms; allow ±1 ms
    assert!((rmssd - 43.87).abs() < 1.0, "RMSSD {rmssd} not close to 43.87");
}

#[tokio::test]
async fn import_health_fit_upserts_on_reimport() {
    let app = common::TestApp::spawn().await;
    import_health(&app, HEALTH_FIT).await;
    import_health(&app, HEALTH_FIT).await; // second import should not duplicate

    let rows: serde_json::Value = app
        .client
        .get(app.url("/health/daily"))
        .bearer_auth(&app.token)
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();

    assert_eq!(rows.as_array().unwrap().len(), 2, "upsert should keep exactly 2 rows");
}

#[tokio::test]
async fn import_health_fit_rejects_invalid_file() {
    let app = common::TestApp::spawn().await;
    let res = import_health(&app, b"not a fit file").await;
    assert_eq!(res.status(), 422);
}
