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

// ── History endpoint ──────────────────────────────────────────────────────────

#[tokio::test]
async fn exercise_history_returns_404_for_unknown_exercise() {
    let app = common::TestApp::spawn().await;
    let res = app.get("/exercises/999/history").await;
    assert_eq!(res.status(), 404);
}

#[tokio::test]
async fn exercise_history_empty_when_no_sets() {
    let app = common::TestApp::spawn().await;
    let ex = app.create_exercise("Squat").await;
    let id = ex["id"].as_i64().unwrap();
    let res = app.get(&format!("/exercises/{id}/history")).await;
    assert_eq!(res.status(), 200);
    let body: serde_json::Value = res.json().await.unwrap();
    assert_eq!(body, serde_json::json!([]));
}

#[tokio::test]
async fn exercise_history_aggregates_sets_per_workout() {
    let app = common::TestApp::spawn().await;
    let ex = app.create_exercise("Bench Press").await;
    let ex_id = ex["id"].as_i64().unwrap();

    // Workout 1: two sets
    let w1 = app.create_workout().await;
    let w1_id = w1["id"].as_i64().unwrap();
    app.add_set(w1_id, ex_id, 1, 10, 60.0).await;
    app.add_set(w1_id, ex_id, 2, 8, 70.0).await;

    // Workout 2: one set
    let w2 = app.create_workout().await;
    let w2_id = w2["id"].as_i64().unwrap();
    app.add_set(w2_id, ex_id, 1, 5, 80.0).await;

    let body: serde_json::Value = app
        .get(&format!("/exercises/{ex_id}/history"))
        .await
        .json()
        .await
        .unwrap();
    let arr = body.as_array().unwrap();
    assert_eq!(arr.len(), 2);

    let p0 = &arr[0];
    assert_eq!(p0["max_weight_kg"], 70.0);
    assert_eq!(p0["reps_at_max"], 8);
    assert_eq!(p0["total_sets"], 2);
    assert_eq!(p0["total_reps"], 18);

    let p1 = &arr[1];
    assert_eq!(p1["max_weight_kg"], 80.0);
    assert_eq!(p1["reps_at_max"], 5);
    assert_eq!(p1["total_sets"], 1);
}

#[tokio::test]
async fn exercise_history_reps_at_max_prefers_higher_weight() {
    let app = common::TestApp::spawn().await;
    let ex = app.create_exercise("Deadlift").await;
    let ex_id = ex["id"].as_i64().unwrap();
    let w = app.create_workout().await;
    let w_id = w["id"].as_i64().unwrap();
    // Heavy set first (lower reps), light set second (higher reps)
    app.add_set(w_id, ex_id, 1, 3, 100.0).await;
    app.add_set(w_id, ex_id, 2, 12, 60.0).await;

    let body: serde_json::Value = app
        .get(&format!("/exercises/{ex_id}/history"))
        .await
        .json()
        .await
        .unwrap();
    let p = &body[0];
    assert_eq!(p["max_weight_kg"], 100.0);
    assert_eq!(p["reps_at_max"], 3);
}

#[tokio::test]
async fn exercise_history_only_includes_that_exercise() {
    let app = common::TestApp::spawn().await;
    let ex1 = app.create_exercise("Squat").await;
    let ex2 = app.create_exercise("Lunge").await;
    let ex1_id = ex1["id"].as_i64().unwrap();
    let ex2_id = ex2["id"].as_i64().unwrap();
    let w = app.create_workout().await;
    let w_id = w["id"].as_i64().unwrap();
    app.add_set(w_id, ex1_id, 1, 5, 100.0).await;
    app.add_set(w_id, ex2_id, 1, 10, 40.0).await;

    let body: serde_json::Value = app
        .get(&format!("/exercises/{ex1_id}/history"))
        .await
        .json()
        .await
        .unwrap();
    assert_eq!(body.as_array().unwrap().len(), 1);
    assert_eq!(body[0]["max_weight_kg"], 100.0);
}

#[tokio::test]
async fn exercise_history_total_volume_computed_correctly() {
    let app = common::TestApp::spawn().await;
    let ex = app.create_exercise("Row").await;
    let ex_id = ex["id"].as_i64().unwrap();
    let w = app.create_workout().await;
    let w_id = w["id"].as_i64().unwrap();
    // 3 sets × 10 reps × 50 kg = 1500
    app.add_set(w_id, ex_id, 1, 10, 50.0).await;
    app.add_set(w_id, ex_id, 2, 10, 50.0).await;
    app.add_set(w_id, ex_id, 3, 10, 50.0).await;

    let body: serde_json::Value = app
        .get(&format!("/exercises/{ex_id}/history"))
        .await
        .json()
        .await
        .unwrap();
    let vol = body[0]["total_volume"].as_f64().unwrap();
    assert!((vol - 1500.0).abs() < 0.01, "expected 1500 got {vol}");
}
