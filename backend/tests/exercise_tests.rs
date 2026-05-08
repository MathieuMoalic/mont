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
async fn list_exercises_sorted_by_recent_use() {
    let app = common::TestApp::spawn().await;
    app.create_exercise("Squat").await;
    app.create_exercise("Bench Press").await;
    app.create_exercise("Deadlift").await;

    let body: Vec<serde_json::Value> = app.get("/exercises").await.json().await.unwrap();
    let names: Vec<&str> = body.iter().map(|e| e["name"].as_str().unwrap()).collect();
    // Most recently created first when no sets exist
    assert_eq!(names, vec!["Deadlift", "Bench Press", "Squat"]);
}

#[tokio::test]
async fn create_exercise_with_duplicate_name_and_equipment_fails() {
    let app = common::TestApp::spawn().await;
    let res1 = app
        .post_json(
            "/exercises",
            &serde_json::json!({ "name": "Curl", "equipment": "Barbell" }),
        )
        .await;
    assert_eq!(res1.status(), 201);
    let res2 = app
        .post_json(
            "/exercises",
            &serde_json::json!({ "name": "Curl", "equipment": "Barbell" }),
        )
        .await;
    assert!(res2.status().is_server_error() || res2.status().is_client_error());
}

#[tokio::test]
async fn create_exercise_with_same_name_different_equipment_succeeds() {
    let app = common::TestApp::spawn().await;
    let res1 = app
        .post_json(
            "/exercises",
            &serde_json::json!({ "name": "Chest Press", "equipment": "Barbell" }),
        )
        .await;
    assert_eq!(res1.status(), 201);
    let body1: serde_json::Value = res1.json().await.unwrap();
    assert_eq!(body1["name"], "Chest Press");
    assert_eq!(body1["equipment"], "Barbell");

    let res2 = app
        .post_json(
            "/exercises",
            &serde_json::json!({ "name": "Chest Press", "equipment": "Dumbbell" }),
        )
        .await;
    assert_eq!(res2.status(), 201);
    let body2: serde_json::Value = res2.json().await.unwrap();
    assert_eq!(body2["name"], "Chest Press");
    assert_eq!(body2["equipment"], "Dumbbell");

    // Verify both exist
    let list: Vec<serde_json::Value> = app.get("/exercises").await.json().await.unwrap();
    assert_eq!(list.len(), 2);
}

#[tokio::test]
async fn create_exercise_without_name_returns_422() {
    let app = common::TestApp::spawn().await;
    let res = app
        .post_json("/exercises", &serde_json::json!({ "notes": "no name" }))
        .await;
    assert_eq!(res.status(), 422);
}

#[tokio::test]
async fn get_exercise_categories_initially_empty() {
    let app = common::TestApp::spawn().await;
    let res = app.get("/exercise-categories").await;
    assert_eq!(res.status(), 200);
    let body: serde_json::Value = res.json().await.unwrap();
    assert_eq!(body["muscle_groups"], serde_json::json!([]));
    assert_eq!(body["equipment"], serde_json::json!([]));
}

#[tokio::test]
async fn update_exercise_categories_round_trip() {
    let app = common::TestApp::spawn().await;
    let res = app
        .put(
            "/exercise-categories",
            serde_json::json!({
                "muscle_groups": [
                    {"name": "Chest", "color_hex": "#ff4a3548"},
                    {"name": "Back", "color_hex": null}
                ],
                "equipment": ["Barbell", "Cable"]
            }),
        )
        .await;
    assert_eq!(res.status(), 204);

    let body: serde_json::Value = app.get("/exercise-categories").await.json().await.unwrap();
    assert_eq!(body["muscle_groups"][0]["name"], "Chest");
    assert_eq!(body["muscle_groups"][0]["color_hex"], "#ff4a3548");
    assert_eq!(body["equipment"], serde_json::json!(["Barbell", "Cable"]));
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

// ── Personal Records endpoint ─────────────────────────────────────────────────

#[tokio::test]
async fn exercise_pr_returns_404_for_unknown_exercise() {
    let app = common::TestApp::spawn().await;
    let res = app.get("/exercises/999/pr").await;
    assert_eq!(res.status(), 404);
}

#[tokio::test]
async fn exercise_pr_returns_all_records() {
    let app = common::TestApp::spawn().await;
    let ex = app.create_exercise("Squat").await;
    let ex_id = ex["id"].as_i64().unwrap();

    // Create multiple workouts with different PRs
    // Workout 1: max weight
    let w1 = app.create_workout().await;
    app.add_set(w1["id"].as_i64().unwrap(), ex_id, 1, 5, 150.0)
        .await;

    // Workout 2: max reps (at lower weight)
    let w2 = app.create_workout().await;
    app.add_set(w2["id"].as_i64().unwrap(), ex_id, 1, 20, 60.0)
        .await;

    // Workout 3: max volume (multiple sets)
    let w3 = app.create_workout().await;
    app.add_set(w3["id"].as_i64().unwrap(), ex_id, 1, 10, 100.0)
        .await;
    app.add_set(w3["id"].as_i64().unwrap(), ex_id, 2, 10, 100.0)
        .await;
    app.add_set(w3["id"].as_i64().unwrap(), ex_id, 3, 10, 100.0)
        .await;

    let pr: serde_json::Value = app
        .get(&format!("/exercises/{ex_id}/pr"))
        .await
        .json()
        .await
        .unwrap();

    // Check max weight
    assert_eq!(pr["max_weight_kg"], 150.0);
    assert_eq!(pr["max_weight_reps"], 5);

    // Check max reps
    assert_eq!(pr["max_reps"], 20);
    assert_eq!(pr["max_reps_weight_kg"], 60.0);

    // Check max volume (3 sets x 10 reps x 100kg = 3000)
    let max_vol = pr["max_volume_workout"].as_f64().unwrap();
    assert!((max_vol - 3000.0).abs() < 0.01);

    // Check best set (weight * reps) - 60kg * 20 reps = 1200
    let best_score = pr["best_set_score"].as_f64().unwrap();
    assert!((best_score - 1200.0).abs() < 0.01);
    assert_eq!(pr["best_set_weight_kg"], 60.0);
    assert_eq!(pr["best_set_reps"], 20);
}
