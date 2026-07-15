mod common;

#[tokio::test]
async fn list_hyrox_days_initially_empty() {
    let app = common::TestApp::spawn().await;
    let body: serde_json::Value = app.get("/hyrox-days").await.json().await.unwrap();
    assert_eq!(body, serde_json::json!([]));
}

#[tokio::test]
async fn upsert_hyrox_day_creates_row() {
    let app = common::TestApp::spawn().await;

    let res = app.put_empty("/hyrox-days/2026-07-15").await;
    assert_eq!(res.status(), 204);

    let body: serde_json::Value = app.get("/hyrox-days").await.json().await.unwrap();
    assert_eq!(body, serde_json::json!([{ "day": "2026-07-15" }]));
}

#[tokio::test]
async fn upsert_hyrox_day_is_idempotent() {
    let app = common::TestApp::spawn().await;

    let first = app.put_empty("/hyrox-days/2026-07-15").await;
    assert_eq!(first.status(), 204);
    let second = app.put_empty("/hyrox-days/2026-07-15").await;
    assert_eq!(second.status(), 204);

    let rows: Vec<serde_json::Value> = app.get("/hyrox-days").await.json().await.unwrap();
    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0], serde_json::json!({ "day": "2026-07-15" }));
}

#[tokio::test]
async fn delete_hyrox_day_removes_row() {
    let app = common::TestApp::spawn().await;

    app.put_empty("/hyrox-days/2026-07-15").await;
    let res = app.delete("/hyrox-days/2026-07-15").await;
    assert_eq!(res.status(), 204);

    let body: serde_json::Value = app.get("/hyrox-days").await.json().await.unwrap();
    assert_eq!(body, serde_json::json!([]));
}

#[tokio::test]
async fn invalid_day_returns_400() {
    let app = common::TestApp::spawn().await;

    let put = app.put_empty("/hyrox-days/not-a-date").await;
    assert_eq!(put.status(), 400);

    let delete = app.delete("/hyrox-days/2026-99-99").await;
    assert_eq!(delete.status(), 400);
}
