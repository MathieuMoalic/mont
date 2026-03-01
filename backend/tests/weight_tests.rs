mod common;

#[tokio::test]
async fn list_weight_initially_empty() {
    let app = common::TestApp::spawn().await;
    let body: serde_json::Value = app.get("/weight").await.json().await.unwrap();
    assert_eq!(body, serde_json::json!([]));
}

#[tokio::test]
async fn create_weight_entry_returns_201() {
    let app = common::TestApp::spawn().await;
    let res = app
        .post_json("/weight", &serde_json::json!({ "weight_kg": 80.5 }))
        .await;
    assert_eq!(res.status(), 201);
    let body: serde_json::Value = res.json().await.unwrap();
    assert!(body["id"].as_i64().is_some());
    assert_eq!(body["weight_kg"], 80.5);
    assert!(body["measured_at"].as_str().is_some());
}

#[tokio::test]
async fn create_weight_entry_with_custom_timestamp() {
    let app = common::TestApp::spawn().await;
    let ts = "2026-01-15T08:00:00Z";
    let body: serde_json::Value = app
        .post_json(
            "/weight",
            &serde_json::json!({ "weight_kg": 79.0, "measured_at": ts }),
        )
        .await
        .json()
        .await
        .unwrap();
    assert_eq!(body["measured_at"], ts);
}

#[tokio::test]
async fn list_weight_returns_entries_ascending() {
    let app = common::TestApp::spawn().await;
    app.post_json(
        "/weight",
        &serde_json::json!({ "weight_kg": 82.0, "measured_at": "2026-01-01T00:00:00Z" }),
    )
    .await;
    app.post_json(
        "/weight",
        &serde_json::json!({ "weight_kg": 81.0, "measured_at": "2026-01-03T00:00:00Z" }),
    )
    .await;
    app.post_json(
        "/weight",
        &serde_json::json!({ "weight_kg": 80.5, "measured_at": "2026-01-02T00:00:00Z" }),
    )
    .await;

    let entries: Vec<serde_json::Value> = app.get("/weight").await.json().await.unwrap();
    assert_eq!(entries.len(), 3);
    // Should be sorted ascending by measured_at
    assert_eq!(entries[0]["weight_kg"], 82.0);
    assert_eq!(entries[1]["weight_kg"], 80.5);
    assert_eq!(entries[2]["weight_kg"], 81.0);
}

#[tokio::test]
async fn delete_weight_entry_returns_204() {
    let app = common::TestApp::spawn().await;
    let entry: serde_json::Value = app
        .post_json("/weight", &serde_json::json!({ "weight_kg": 78.0 }))
        .await
        .json()
        .await
        .unwrap();
    let id = entry["id"].as_i64().unwrap();

    let res = app.delete(&format!("/weight/{id}")).await;
    assert_eq!(res.status(), 204);
}

#[tokio::test]
async fn delete_weight_entry_removes_it() {
    let app = common::TestApp::spawn().await;
    let entry: serde_json::Value = app
        .post_json("/weight", &serde_json::json!({ "weight_kg": 77.5 }))
        .await
        .json()
        .await
        .unwrap();
    let id = entry["id"].as_i64().unwrap();
    app.delete(&format!("/weight/{id}")).await;

    let list: Vec<serde_json::Value> = app.get("/weight").await.json().await.unwrap();
    assert!(list.is_empty());
}

#[tokio::test]
async fn delete_nonexistent_weight_entry_returns_404() {
    let app = common::TestApp::spawn().await;
    let res = app.delete("/weight/9999").await;
    assert_eq!(res.status(), 404);
}

#[tokio::test]
async fn create_weight_entry_missing_weight_returns_422() {
    let app = common::TestApp::spawn().await;
    let res = app
        .post_json("/weight", &serde_json::json!({ "notes": "no weight field" }))
        .await;
    assert_eq!(res.status(), 422);
}
