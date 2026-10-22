//! Integration tests for the `/maps/*` endpoints (validation paths; the full
//! tile build needs java + osmium + mkgmap.jar and is verified manually).

use reqwest::multipart::Part;
use serde_json::json;

mod common;

use common::TestApp;

fn sample_gpx() -> Vec<u8> {
    br#"<?xml version="1.0" encoding="UTF-8"?>
<gpx version="1.1" creator="test">
  <trk><trkseg>
    <trkpt lat="52.20" lon="20.90"/>
    <trkpt lat="52.25" lon="21.00"/>
  </trkseg></trk>
</gpx>"#
        .to_vec()
}

#[tokio::test]
async fn ready_reports_unavailable_without_config() {
    let app = TestApp::spawn().await;
    let res = app.get("/maps/ready").await;
    assert_eq!(res.status(), 200);
    let body: serde_json::Value = res.json().await.unwrap();
    // java/osmium may or may not be on PATH in the test env; without the jar
    // the server is never ready.
    assert_eq!(body["ready"], json!(false));
}

#[tokio::test]
async fn create_job_without_jar_is_400() {
    let app = TestApp::spawn().await;
    let form = reqwest::multipart::Form::new()
        .part("file", Part::bytes(sample_gpx()).file_name("route.gpx"));
    let res = app
        .client
        .post(app.url("/maps/jobs"))
        .bearer_auth(&app.token)
        .multipart(form)
        .send()
        .await
        .unwrap();
    assert_eq!(res.status(), 400);
    let text = res.text().await.unwrap();
    assert!(text.contains("MONT_MKGMAP_JAR"), "body: {text}");
}

#[tokio::test]
async fn create_job_with_missing_jar_file_is_400() {
    let app = TestApp::spawn_custom(|cfg| {
        cfg.mkgmap_jar = Some("/nonexistent/mkgmap.jar".into());
    })
    .await;
    let form = reqwest::multipart::Form::new()
        .part("file", Part::bytes(sample_gpx()).file_name("route.gpx"));
    let res = app
        .client
        .post(app.url("/maps/jobs"))
        .bearer_auth(&app.token)
        .multipart(form)
        .send()
        .await
        .unwrap();
    assert_eq!(res.status(), 400);
    let text = res.text().await.unwrap();
    assert!(text.contains("mkgmap.jar"), "body: {text}");
}

#[tokio::test]
async fn create_job_unknown_style_is_400() {
    let app = TestApp::spawn_custom(|cfg| {
        cfg.mkgmap_jar = Some("/nonexistent/mkgmap.jar".into());
    })
    .await;
    let form = reqwest::multipart::Form::new()
        .part("file", Part::bytes(sample_gpx()).file_name("route.gpx"))
        .text("style", "nope");
    let res = app
        .client
        .post(app.url("/maps/jobs"))
        .bearer_auth(&app.token)
        .multipart(form)
        .send()
        .await
        .unwrap();
    assert_eq!(res.status(), 400);
    let text = res.text().await.unwrap();
    assert!(text.contains("Unknown style"), "body: {text}");
}

#[tokio::test]
async fn create_job_invalid_gpx_is_422() {
    let app = TestApp::spawn_custom(|cfg| {
        cfg.mkgmap_jar = Some("/nonexistent/mkgmap.jar".into());
    })
    .await;
    let form = reqwest::multipart::Form::new()
        .part(
            "file",
            Part::bytes(b"not xml".to_vec()).file_name("route.gpx"),
        )
        .text("style", "default");
    let res = app
        .client
        .post(app.url("/maps/jobs"))
        .bearer_auth(&app.token)
        .multipart(form)
        .send()
        .await
        .unwrap();
    assert_eq!(res.status(), 422);
}

#[tokio::test]
async fn create_job_without_file_field_is_400() {
    let app = TestApp::spawn_custom(|cfg| {
        cfg.mkgmap_jar = Some("/nonexistent/mkgmap.jar".into());
    })
    .await;
    let form = reqwest::multipart::Form::new().text("style", "default");
    let res = app
        .client
        .post(app.url("/maps/jobs"))
        .bearer_auth(&app.token)
        .multipart(form)
        .send()
        .await
        .unwrap();
    assert_eq!(res.status(), 400);
    let text = res.text().await.unwrap();
    assert!(text.contains("Missing `file`"), "body: {text}");
}

#[tokio::test]
async fn job_status_unknown_id_is_404() {
    let app = TestApp::spawn().await;
    let res = app.get("/maps/jobs/nope").await;
    assert_eq!(res.status(), 404);
}

#[tokio::test]
async fn job_download_unknown_id_is_404() {
    let app = TestApp::spawn().await;
    let res = app.get("/maps/jobs/nope/download").await;
    assert_eq!(res.status(), 404);
}

#[tokio::test]
async fn maps_endpoints_require_auth() {
    let app = TestApp::spawn().await;
    assert_eq!(
        app.client
            .get(app.url("/maps/ready"))
            .send()
            .await
            .unwrap()
            .status(),
        401
    );
    assert_eq!(
        app.client
            .get(app.url("/maps/jobs/abc"))
            .send()
            .await
            .unwrap()
            .status(),
        401
    );
}
