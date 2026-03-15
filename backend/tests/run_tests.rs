mod common;

// A minimal valid GPX with 3 track points and heart rate extensions
const SAMPLE_GPX: &str = r#"<?xml version="1.0" encoding="UTF-8"?>
<gpx version="1.1" creator="GadgetBridge"
     xmlns="http://www.topografix.com/GPX/1/1"
     xmlns:gpxtpx="http://www.garmin.com/xmlschemas/TrackPointExtension/v1">
  <trk>
    <trkseg>
      <trkpt lat="48.8566" lon="2.3522">
        <ele>35.0</ele>
        <time>2026-01-15T09:00:00Z</time>
        <extensions><gpxtpx:TrackPointExtension><gpxtpx:hr>140</gpxtpx:hr></gpxtpx:TrackPointExtension></extensions>
      </trkpt>
      <trkpt lat="48.8576" lon="2.3532">
        <ele>37.5</ele>
        <time>2026-01-15T09:05:00Z</time>
        <extensions><gpxtpx:TrackPointExtension><gpxtpx:hr>155</gpxtpx:hr></gpxtpx:TrackPointExtension></extensions>
      </trkpt>
      <trkpt lat="48.8586" lon="2.3542">
        <ele>36.0</ele>
        <time>2026-01-15T09:10:00Z</time>
        <extensions><gpxtpx:TrackPointExtension><gpxtpx:hr>160</gpxtpx:hr></gpxtpx:TrackPointExtension></extensions>
      </trkpt>
    </trkseg>
  </trk>
</gpx>"#;

async fn import_sample(app: &common::TestApp) -> serde_json::Value {
    let part = reqwest::multipart::Part::bytes(SAMPLE_GPX.as_bytes().to_vec())
        .file_name("run.gpx")
        .mime_str("application/gpx+xml")
        .unwrap();
    let form = reqwest::multipart::Form::new().part("file", part);

    app.client
        .post(app.url("/runs/import"))
        .bearer_auth(&app.token)
        .multipart(form)
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap()
}

#[tokio::test]
async fn import_run_returns_201() {
    let app = common::TestApp::spawn().await;
    let part = reqwest::multipart::Part::bytes(SAMPLE_GPX.as_bytes().to_vec())
        .file_name("run.gpx")
        .mime_str("application/gpx+xml")
        .unwrap();
    let form = reqwest::multipart::Form::new().part("file", part);

    let res = app
        .client
        .post(app.url("/runs/import"))
        .bearer_auth(&app.token)
        .multipart(form)
        .send()
        .await
        .unwrap();
    assert_eq!(res.status(), 201);
}

#[tokio::test]
async fn import_run_extracts_distance_and_duration() {
    let app = common::TestApp::spawn().await;
    let body = import_sample(&app).await;

    assert!(body["id"].as_i64().is_some());
    let distance = body["distance_m"].as_f64().unwrap();
    assert!(distance > 100.0, "expected distance > 100m, got {distance}");
    assert_eq!(body["duration_s"], 600); // 10 minutes
    assert_eq!(body["started_at"], "2026-01-15T09:00:00Z");
}

#[tokio::test]
async fn import_run_extracts_heart_rate() {
    let app = common::TestApp::spawn().await;
    let body = import_sample(&app).await;

    assert!(body["avg_hr"].as_i64().is_some());
    assert_eq!(body["max_hr"], 160);
}

#[tokio::test]
async fn import_run_extracts_elevation_gain() {
    let app = common::TestApp::spawn().await;
    let body = import_sample(&app).await;

    // ele goes 35 → 37.5 → 36 so gain should be 2.5m
    let gain = body["elevation_gain_m"].as_f64().unwrap();
    assert!((gain - 2.5).abs() < 0.01, "expected ~2.5m gain, got {gain}");
}

#[tokio::test]
async fn list_runs_initially_empty() {
    let app = common::TestApp::spawn().await;
    let body: serde_json::Value = app.get("/runs").await.json().await.unwrap();
    assert_eq!(body, serde_json::json!([]));
}

#[tokio::test]
async fn list_runs_shows_imported_run() {
    let app = common::TestApp::spawn().await;
    import_sample(&app).await;
    import_sample(&app).await;

    let runs: Vec<serde_json::Value> = app.get("/runs").await.json().await.unwrap();
    assert_eq!(runs.len(), 2);
}

#[tokio::test]
async fn get_run_returns_detail_with_route() {
    let app = common::TestApp::spawn().await;
    let run = import_sample(&app).await;
    let id = run["id"].as_i64().unwrap();

    let detail: serde_json::Value = app.get(&format!("/runs/{id}")).await.json().await.unwrap();
    let route = detail["route"].as_array().unwrap();
    assert_eq!(route.len(), 3);
    assert!(route[0]["lat"].as_f64().is_some());
    assert!(route[0]["lon"].as_f64().is_some());
}

#[tokio::test]
async fn get_nonexistent_run_returns_404() {
    let app = common::TestApp::spawn().await;
    let res = app.get("/runs/9999").await;
    assert_eq!(res.status(), 404);
}

#[tokio::test]
async fn delete_run_returns_204() {
    let app = common::TestApp::spawn().await;
    let run = import_sample(&app).await;
    let id = run["id"].as_i64().unwrap();

    let res = app.delete(&format!("/runs/{id}")).await;
    assert_eq!(res.status(), 204);
}

#[tokio::test]
async fn delete_run_removes_it_from_list() {
    let app = common::TestApp::spawn().await;
    let run = import_sample(&app).await;
    let id = run["id"].as_i64().unwrap();
    app.delete(&format!("/runs/{id}")).await;

    let runs: Vec<serde_json::Value> = app.get("/runs").await.json().await.unwrap();
    assert!(runs.is_empty());
}

#[tokio::test]
async fn delete_nonexistent_run_returns_404() {
    let app = common::TestApp::spawn().await;
    let res = app.delete("/runs/9999").await;
    assert_eq!(res.status(), 404);
}

#[tokio::test]
async fn import_without_file_field_returns_400() {
    let app = common::TestApp::spawn().await;
    let form = reqwest::multipart::Form::new();
    let res = app
        .client
        .post(app.url("/runs/import"))
        .bearer_auth(&app.token)
        .multipart(form)
        .send()
        .await
        .unwrap();
    assert_eq!(res.status(), 400);
}

#[tokio::test]
async fn import_invalid_gpx_returns_422() {
    let app = common::TestApp::spawn().await;
    let part = reqwest::multipart::Part::bytes(b"this is not gpx".to_vec())
        .file_name("bad.gpx");
    let form = reqwest::multipart::Form::new().part("file", part);
    let res = app
        .client
        .post(app.url("/runs/import"))
        .bearer_auth(&app.token)
        .multipart(form)
        .send()
        .await
        .unwrap();
    assert_eq!(res.status(), 422);
}

// ── Personal records tests ───────────────────────────────────────────────────

async fn insert_run(app: &common::TestApp, started_at: &str, duration_s: i64, distance_m: f64) -> i64 {
    let row: (i64,) = sqlx::query_as(
        "INSERT INTO runs (started_at, duration_s, distance_m, route_json) VALUES (?, ?, ?, '[]') RETURNING id",
    )
    .bind(started_at)
    .bind(duration_s)
    .bind(distance_m)
    .fetch_one(&app.pool)
    .await
    .unwrap();
    row.0
}

#[tokio::test]
async fn prs_empty_when_no_runs() {
    let app = common::TestApp::spawn().await;
    let res = app.get("/runs/prs").await;
    assert_eq!(res.status(), 200);
    let body: serde_json::Value = res.json().await.unwrap();
    assert_eq!(body, serde_json::json!([]));
}

#[tokio::test]
async fn prs_returns_5k_record() {
    let app = common::TestApp::spawn().await;
    // 5 km in 25 min = 5:00/km pace
    insert_run(&app, "2026-01-01T08:00:00Z", 1500, 5000.0).await;
    let prs: Vec<serde_json::Value> = app.get("/runs/prs").await.json().await.unwrap();
    let five_k = prs.iter().find(|p| p["distance_label"] == "5 km").unwrap();
    assert_eq!(five_k["estimated_seconds"].as_f64().unwrap(), 1500.0);
}

#[tokio::test]
async fn prs_picks_fastest_run_for_distance() {
    let app = common::TestApp::spawn().await;
    // Two 5k-qualifying runs; second is faster
    insert_run(&app, "2026-01-01T08:00:00Z", 1800, 5200.0).await; // ~28 min for 5k pace
    insert_run(&app, "2026-01-02T08:00:00Z", 1500, 5100.0).await; // ~24.5 min for 5k pace
    let prs: Vec<serde_json::Value> = app.get("/runs/prs").await.json().await.unwrap();
    let five_k = prs.iter().find(|p| p["distance_label"] == "5 km").unwrap();
    // Second run is faster — estimated_seconds should be ~1470
    assert!(five_k["estimated_seconds"].as_f64().unwrap() < 1600.0);
}

#[tokio::test]
async fn prs_does_not_include_distance_without_qualifying_run() {
    let app = common::TestApp::spawn().await;
    // Only a 3 km run — should not appear for 5k/10k/etc
    insert_run(&app, "2026-01-01T08:00:00Z", 900, 3000.0).await;
    let prs: Vec<serde_json::Value> = app.get("/runs/prs").await.json().await.unwrap();
    assert!(prs.iter().find(|p| p["distance_label"] == "5 km").is_none());
    // But 1k should appear (3k > 1k * 0.95)
    assert!(prs.iter().find(|p| p["distance_label"] == "1 km").is_some());
}

#[tokio::test]
async fn mark_run_invalid_returns_204() {
    let app = common::TestApp::spawn().await;
    insert_run(&app, "2026-01-01T08:00:00Z", 1500, 5000.0).await;
    let runs: Vec<serde_json::Value> = app.get("/runs").await.json().await.unwrap();
    let id = runs[0]["id"].as_i64().unwrap();
    let res = app.patch(&format!("/runs/{id}"), serde_json::json!({"is_invalid": true})).await;
    assert_eq!(res.status(), 204);
}

#[tokio::test]
async fn invalid_run_is_excluded_from_prs() {
    let app = common::TestApp::spawn().await;
    insert_run(&app, "2026-01-01T08:00:00Z", 1500, 5000.0).await;
    let runs: Vec<serde_json::Value> = app.get("/runs").await.json().await.unwrap();
    let id = runs[0]["id"].as_i64().unwrap();
    // Mark as invalid
    app.patch(&format!("/runs/{id}"), serde_json::json!({"is_invalid": true})).await;
    // Should not appear in PRs
    let prs: Vec<serde_json::Value> = app.get("/runs/prs").await.json().await.unwrap();
    assert!(prs.iter().find(|p| p["distance_label"] == "5 km").is_none());
}

#[tokio::test]
async fn invalid_run_still_appears_in_list() {
    let app = common::TestApp::spawn().await;
    insert_run(&app, "2026-01-01T08:00:00Z", 1500, 5000.0).await;
    let runs: Vec<serde_json::Value> = app.get("/runs").await.json().await.unwrap();
    let id = runs[0]["id"].as_i64().unwrap();
    app.patch(&format!("/runs/{id}"), serde_json::json!({"is_invalid": true})).await;
    let runs: Vec<serde_json::Value> = app.get("/runs").await.json().await.unwrap();
    assert_eq!(runs.len(), 1);
    assert_eq!(runs[0]["is_invalid"], true);
}

#[tokio::test]
async fn can_unmark_invalid_run() {
    let app = common::TestApp::spawn().await;
    insert_run(&app, "2026-01-01T08:00:00Z", 1500, 5000.0).await;
    let runs: Vec<serde_json::Value> = app.get("/runs").await.json().await.unwrap();
    let id = runs[0]["id"].as_i64().unwrap();
    app.patch(&format!("/runs/{id}"), serde_json::json!({"is_invalid": true})).await;
    app.patch(&format!("/runs/{id}"), serde_json::json!({"is_invalid": false})).await;
    let runs: Vec<serde_json::Value> = app.get("/runs").await.json().await.unwrap();
    assert_eq!(runs[0]["is_invalid"], false);
    // Should be back in PRs
    let prs: Vec<serde_json::Value> = app.get("/runs/prs").await.json().await.unwrap();
    assert!(prs.iter().find(|p| p["distance_label"] == "5 km").is_some());
}

#[tokio::test]
async fn mark_nonexistent_run_invalid_returns_404() {
    let app = common::TestApp::spawn().await;
    let res = app.patch("/runs/9999", serde_json::json!({"is_invalid": true})).await;
    assert_eq!(res.status(), 404);
}

fn make_gpx_with_type(activity_type: &str) -> Vec<u8> {
    format!(r#"<?xml version="1.0" encoding="UTF-8"?>
<gpx version="1.1" creator="GadgetBridge"
     xmlns="http://www.topografix.com/GPX/1/1">
  <trk>
    <type>{activity_type}</type>
    <trkseg>
      <trkpt lat="48.8566" lon="2.3522"><ele>35.0</ele><time>2026-02-01T09:00:00Z</time></trkpt>
      <trkpt lat="48.8576" lon="2.3532"><ele>37.5</ele><time>2026-02-01T09:05:00Z</time></trkpt>
    </trkseg>
  </trk>
</gpx>"#).into_bytes()
}

#[tokio::test]
async fn cycling_gpx_is_rejected_on_import() {
    let app = common::TestApp::spawn().await;
    let part = reqwest::multipart::Part::bytes(make_gpx_with_type("cycling"))
        .file_name("cycling.gpx");
    let form = reqwest::multipart::Form::new().part("file", part);
    let res = app.client.post(app.url("/runs/import"))
        .bearer_auth(&app.token).multipart(form).send().await.unwrap();
    assert_eq!(res.status(), 422);
}

#[tokio::test]
async fn running_gpx_with_type_is_accepted() {
    let app = common::TestApp::spawn().await;
    let part = reqwest::multipart::Part::bytes(make_gpx_with_type("running"))
        .file_name("run.gpx");
    let form = reqwest::multipart::Form::new().part("file", part);
    let res = app.client.post(app.url("/runs/import"))
        .bearer_auth(&app.token).multipart(form).send().await.unwrap();
    assert_eq!(res.status(), 201);
}

#[tokio::test]
async fn gpx_without_type_field_is_accepted() {
    let app = common::TestApp::spawn().await;
    // SAMPLE_GPX has no <type> element — should still be accepted
    let part = reqwest::multipart::Part::bytes(SAMPLE_GPX.as_bytes().to_vec())
        .file_name("run.gpx");
    let form = reqwest::multipart::Form::new().part("file", part);
    let res = app.client.post(app.url("/runs/import"))
        .bearer_auth(&app.token).multipart(form).send().await.unwrap();
    assert_eq!(res.status(), 201);
}

// ── FIT import tests ──────────────────────────────────────────────────────────
//
// A minimal valid FIT file: 3 GPS record messages + 1 session message (sport=running).
// Generated from Python using the FIT binary protocol spec.
// Track: Paris area, 5-min intervals, elevation 35→37.5→36m, HR 140/155/160 bpm,
// cadence 160/162/164 spm (stored as strides/min 80/81/82), speed 3.0–3.2 m/s.
// Expected: started_at=2026-01-15T09:00:00Z, duration=600s, distance≈265m.
const SAMPLE_FIT: &[u8] = &[
    0x0e, 0x10, 0x43, 0x08, 0x78, 0x00, 0x00, 0x00, 0x2e, 0x46, 0x49, 0x54, 0xf0, 0x1c,
    0x40, 0x00, 0x00, 0x14, 0x00, 0x07, 0xfd, 0x04, 0x86, 0x00, 0x04, 0x85, 0x01, 0x04,
    0x85, 0x02, 0x02, 0x84, 0x03, 0x01, 0x02, 0x04, 0x01, 0x02, 0x06, 0x02, 0x84, 0x00,
    0x90, 0x60, 0xcb, 0x43, 0x96, 0x12, 0xbe, 0x22, 0x77, 0x34, 0xac, 0x01, 0x73, 0x0a,
    0x8c, 0x50, 0xb8, 0x0b, 0x00, 0xbc, 0x61, 0xcb, 0x43, 0x31, 0x41, 0xbe, 0x22, 0x12,
    0x63, 0xac, 0x01, 0x80, 0x0a, 0x9b, 0x51, 0x1c, 0x0c, 0x00, 0xe8, 0x62, 0xcb, 0x43,
    0xcb, 0x6f, 0xbe, 0x22, 0xac, 0x91, 0xac, 0x01, 0x78, 0x0a, 0xa0, 0x52, 0x80, 0x0c,
    0x41, 0x00, 0x00, 0x12, 0x00, 0x05, 0xfd, 0x04, 0x86, 0x05, 0x01, 0x00, 0x07, 0x04,
    0x86, 0x09, 0x04, 0x86, 0x0e, 0x01, 0x02, 0x01, 0x14, 0x64, 0xcb, 0x43, 0x01, 0xc0,
    0x27, 0x09, 0x00, 0xce, 0x67, 0x00, 0x00, 0x9b, 0xa0, 0xf4,
];

async fn import_fit(app: &common::TestApp) -> reqwest::Response {
    let part = reqwest::multipart::Part::bytes(SAMPLE_FIT.to_vec())
        .file_name("run.fit")
        .mime_str("application/octet-stream")
        .unwrap();
    let form = reqwest::multipart::Form::new().part("file", part);
    app.client
        .post(app.url("/runs/import/fit"))
        .bearer_auth(&app.token)
        .multipart(form)
        .send()
        .await
        .unwrap()
}

#[tokio::test]
async fn import_fit_returns_201() {
    let app = common::TestApp::spawn().await;
    let res = import_fit(&app).await;
    assert_eq!(res.status(), 201);
}

#[tokio::test]
async fn import_fit_extracts_distance_duration_and_timestamp() {
    let app = common::TestApp::spawn().await;
    let body: serde_json::Value = import_fit(&app).await.json().await.unwrap();
    assert!(body["id"].as_i64().is_some());
    assert_eq!(body["duration_s"], 600);
    assert_eq!(body["started_at"], "2026-01-15T09:00:00Z");
    let dist = body["distance_m"].as_f64().unwrap();
    assert!(dist > 100.0, "expected distance > 100m, got {dist}");
}

#[tokio::test]
async fn import_fit_extracts_heart_rate() {
    let app = common::TestApp::spawn().await;
    let body: serde_json::Value = import_fit(&app).await.json().await.unwrap();
    let avg_hr = body["avg_hr"].as_i64().unwrap();
    assert!(avg_hr >= 140 && avg_hr <= 160, "avg_hr={avg_hr} out of expected range");
    let max_hr = body["max_hr"].as_i64().unwrap();
    assert_eq!(max_hr, 160);
}

#[tokio::test]
async fn import_fit_appears_in_run_list() {
    let app = common::TestApp::spawn().await;
    import_fit(&app).await;
    let runs: Vec<serde_json::Value> = app.get("/runs").await.json().await.unwrap();
    assert_eq!(runs.len(), 1);
}

#[tokio::test]
async fn import_fit_invalid_bytes_returns_422() {
    let app = common::TestApp::spawn().await;
    let part = reqwest::multipart::Part::bytes(b"not a fit file".to_vec())
        .file_name("run.fit");
    let form = reqwest::multipart::Form::new().part("file", part);
    let res = app.client.post(app.url("/runs/import/fit"))
        .bearer_auth(&app.token).multipart(form).send().await.unwrap();
    assert_eq!(res.status(), 422);
}
