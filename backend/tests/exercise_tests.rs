mod common;

#[tokio::test]
async fn list_exercises_initially_empty() {
    let app = common::TestApp::spawn().await;
    let res = app.get("/exercises").await;
    assert_eq!(res.status(), 200);
    let body: serde_json::Value = res.json().await.unwrap();
    assert_eq!(body, serde_json::json!([]));
}

#[tokio::test]
async fn create_exercise_returns_201_with_data() {
    let app = common::TestApp::spawn().await;
    let res = app
        .post_json("/exercises", &serde_json::json!({ "name": "Bench Press" }))
        .await;
    assert_eq!(res.status(), 201);
    let body: serde_json::Value = res.json().await.unwrap();
    assert!(body["id"].as_i64().is_some());
    assert_eq!(body["name"], "Bench Press");
    assert!(body["notes"].is_null());
}

#[tokio::test]
async fn create_exercise_with_notes() {
    let app = common::TestApp::spawn().await;
    let res = app
        .post_json(
            "/exercises",
            &serde_json::json!({ "name": "Squat", "notes": "Keep back straight" }),
        )
        .await;
    assert_eq!(res.status(), 201);
    let body: serde_json::Value = res.json().await.unwrap();
    assert_eq!(body["notes"], "Keep back straight");
}

#[tokio::test]
async fn list_exercises_returns_created_exercises() {
    let app = common::TestApp::spawn().await;
    app.create_exercise("Pull-up").await;
    app.create_exercise("Dip").await;

    let res = app.get("/exercises").await;
    let body: serde_json::Value = res.json().await.unwrap();
    assert_eq!(body.as_array().unwrap().len(), 2);
}

#[tokio::test]
async fn list_exercises_sorted_alphabetically() {
    let app = common::TestApp::spawn().await;
    app.create_exercise("Squat").await;
    app.create_exercise("Bench Press").await;
    app.create_exercise("Deadlift").await;

    let body: Vec<serde_json::Value> = app.get("/exercises").await.json().await.unwrap();
    let names: Vec<&str> = body.iter().map(|e| e["name"].as_str().unwrap()).collect();
    assert_eq!(names, vec!["Bench Press", "Deadlift", "Squat"]);
}

#[tokio::test]
async fn create_exercise_with_duplicate_name_fails() {
    let app = common::TestApp::spawn().await;
    let res1 = app
        .post_json("/exercises", &serde_json::json!({ "name": "Curl" }))
        .await;
    assert_eq!(res1.status(), 201);
    let res2 = app
        .post_json("/exercises", &serde_json::json!({ "name": "Curl" }))
        .await;
    assert!(res2.status().is_server_error() || res2.status().is_client_error());
}

#[tokio::test]
async fn create_exercise_without_name_returns_422() {
    let app = common::TestApp::spawn().await;
    let res = app
        .post_json("/exercises", &serde_json::json!({ "notes": "no name" }))
        .await;
    assert_eq!(res.status(), 422);
}
