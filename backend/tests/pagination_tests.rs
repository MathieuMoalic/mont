mod common;

use common::TestApp;

// ── Workout Pagination ──────────────────────────────────────────────────────

#[tokio::test]
async fn list_workouts_default_pagination() {
    let app = TestApp::spawn().await;

    // Create 5 workouts
    for _ in 0..5 {
        app.post_empty("/workouts").await;
    }

    let res = app.get("/workouts").await;
    assert_eq!(res.status(), 200);

    let workouts: Vec<serde_json::Value> = res.json().await.unwrap();
    assert_eq!(workouts.len(), 5);
}

#[tokio::test]
async fn list_workouts_with_limit() {
    let app = TestApp::spawn().await;

    // Create 10 workouts
    for _ in 0..10 {
        app.post_empty("/workouts").await;
    }

    let res = app.get("/workouts?limit=3").await;
    assert_eq!(res.status(), 200);

    let workouts: Vec<serde_json::Value> = res.json().await.unwrap();
    assert_eq!(workouts.len(), 3);
}

#[tokio::test]
async fn list_workouts_with_offset() {
    let app = TestApp::spawn().await;

    // Create 5 workouts
    for _ in 0..5 {
        app.post_empty("/workouts").await;
    }

    let res = app.get("/workouts?offset=2").await;
    assert_eq!(res.status(), 200);

    let workouts: Vec<serde_json::Value> = res.json().await.unwrap();
    assert_eq!(workouts.len(), 3); // 5 - 2 offset = 3
}

#[tokio::test]
async fn list_workouts_with_limit_and_offset() {
    let app = TestApp::spawn().await;

    // Create 10 workouts
    for _ in 0..10 {
        app.post_empty("/workouts").await;
    }

    let res = app.get("/workouts?limit=3&offset=2").await;
    assert_eq!(res.status(), 200);

    let workouts: Vec<serde_json::Value> = res.json().await.unwrap();
    assert_eq!(workouts.len(), 3);
}

#[tokio::test]
async fn list_workouts_offset_beyond_count_returns_empty() {
    let app = TestApp::spawn().await;

    // Create 3 workouts
    for _ in 0..3 {
        app.post_empty("/workouts").await;
    }

    let res = app.get("/workouts?offset=100").await;
    assert_eq!(res.status(), 200);

    let workouts: Vec<serde_json::Value> = res.json().await.unwrap();
    assert!(workouts.is_empty());
}

// ── Exercise Pagination ─────────────────────────────────────────────────────

#[tokio::test]
async fn list_exercises_default_pagination() {
    let app = TestApp::spawn().await;

    for i in 0..5 {
        app.create_exercise(&format!("Exercise {}", i)).await;
    }

    let res = app.get("/exercises").await;
    assert_eq!(res.status(), 200);

    let exercises: Vec<serde_json::Value> = res.json().await.unwrap();
    assert_eq!(exercises.len(), 5);
}

#[tokio::test]
async fn list_exercises_with_limit() {
    let app = TestApp::spawn().await;

    for i in 0..10 {
        app.create_exercise(&format!("Exercise {}", i)).await;
    }

    let res = app.get("/exercises?limit=4").await;
    assert_eq!(res.status(), 200);

    let exercises: Vec<serde_json::Value> = res.json().await.unwrap();
    assert_eq!(exercises.len(), 4);
}

#[tokio::test]
async fn list_exercises_with_limit_and_offset() {
    let app = TestApp::spawn().await;

    for i in 0..10 {
        app.create_exercise(&format!("Exercise {}", i)).await;
    }

    let res = app.get("/exercises?limit=3&offset=5").await;
    assert_eq!(res.status(), 200);

    let exercises: Vec<serde_json::Value> = res.json().await.unwrap();
    assert_eq!(exercises.len(), 3);
}

// ── Exercise History Pagination ─────────────────────────────────────────────

#[tokio::test]
async fn exercise_history_with_pagination() {
    let app = TestApp::spawn().await;

    let exercise = app.create_exercise("Bench Press").await;
    let exercise_id = exercise["id"].as_i64().unwrap();

    // Create 5 workouts with sets
    for _ in 0..5 {
        let workout = app.create_workout().await;
        let workout_id = workout["id"].as_i64().unwrap();
        app.add_set(workout_id, exercise_id, 1, 10, 100.0).await;
    }

    let res = app
        .get(&format!("/exercises/{}/history?limit=2", exercise_id))
        .await;
    assert_eq!(res.status(), 200);

    let history: Vec<serde_json::Value> = res.json().await.unwrap();
    assert_eq!(history.len(), 2);
}

#[tokio::test]
async fn exercise_history_with_offset() {
    let app = TestApp::spawn().await;

    let exercise = app.create_exercise("Squat").await;
    let exercise_id = exercise["id"].as_i64().unwrap();

    // Create 5 workouts with sets
    for _ in 0..5 {
        let workout = app.create_workout().await;
        let workout_id = workout["id"].as_i64().unwrap();
        app.add_set(workout_id, exercise_id, 1, 8, 150.0).await;
    }

    let res = app
        .get(&format!("/exercises/{}/history?offset=3", exercise_id))
        .await;
    assert_eq!(res.status(), 200);

    let history: Vec<serde_json::Value> = res.json().await.unwrap();
    assert_eq!(history.len(), 2); // 5 - 3 = 2
}

// ── Weight Pagination ───────────────────────────────────────────────────────

#[tokio::test]
async fn list_weight_default_pagination() {
    let app = TestApp::spawn().await;

    for i in 0..5 {
        app.post_json(
            "/weight",
            &serde_json::json!({ "weight_kg": 70.0 + i as f64 }),
        )
        .await;
    }

    let res = app.get("/weight").await;
    assert_eq!(res.status(), 200);

    let entries: Vec<serde_json::Value> = res.json().await.unwrap();
    assert_eq!(entries.len(), 5);
}

#[tokio::test]
async fn list_weight_with_limit() {
    let app = TestApp::spawn().await;

    for i in 0..10 {
        app.post_json(
            "/weight",
            &serde_json::json!({ "weight_kg": 70.0 + i as f64 }),
        )
        .await;
    }

    let res = app.get("/weight?limit=3").await;
    assert_eq!(res.status(), 200);

    let entries: Vec<serde_json::Value> = res.json().await.unwrap();
    assert_eq!(entries.len(), 3);
}

#[tokio::test]
async fn list_weight_with_limit_and_offset() {
    let app = TestApp::spawn().await;

    for i in 0..10 {
        app.post_json(
            "/weight",
            &serde_json::json!({ "weight_kg": 70.0 + i as f64 }),
        )
        .await;
    }

    let res = app.get("/weight?limit=4&offset=3").await;
    assert_eq!(res.status(), 200);

    let entries: Vec<serde_json::Value> = res.json().await.unwrap();
    assert_eq!(entries.len(), 4);
}

// ── Runs Pagination ─────────────────────────────────────────────────────────

#[tokio::test]
async fn list_runs_with_pagination() {
    let app = TestApp::spawn().await;

    // Initially empty
    let res = app.get("/runs?limit=10").await;
    assert_eq!(res.status(), 200);

    let runs: Vec<serde_json::Value> = res.json().await.unwrap();
    assert!(runs.is_empty());
}

// ── Health Pagination ───────────────────────────────────────────────────────

#[tokio::test]
async fn list_health_with_pagination() {
    let app = TestApp::spawn().await;

    // Initially empty
    let res = app.get("/health/daily?limit=10").await;
    assert_eq!(res.status(), 200);

    let health: Vec<serde_json::Value> = res.json().await.unwrap();
    assert!(health.is_empty());
}

// ── Edge Cases ──────────────────────────────────────────────────────────────

#[tokio::test]
async fn pagination_with_zero_limit_returns_empty() {
    let app = TestApp::spawn().await;

    for _ in 0..5 {
        app.post_empty("/workouts").await;
    }

    let res = app.get("/workouts?limit=0").await;
    assert_eq!(res.status(), 200);

    let workouts: Vec<serde_json::Value> = res.json().await.unwrap();
    assert!(workouts.is_empty());
}

#[tokio::test]
async fn pagination_with_large_limit_returns_all() {
    let app = TestApp::spawn().await;

    for _ in 0..5 {
        app.post_empty("/workouts").await;
    }

    let res = app.get("/workouts?limit=1000").await;
    assert_eq!(res.status(), 200);

    let workouts: Vec<serde_json::Value> = res.json().await.unwrap();
    assert_eq!(workouts.len(), 5);
}
