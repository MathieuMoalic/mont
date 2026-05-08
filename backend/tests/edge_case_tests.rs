mod common;

use common::TestApp;

// ── Exercise Edge Cases ─────────────────────────────────────────────────────

#[tokio::test]
async fn exercise_name_with_special_characters() {
    let app = TestApp::spawn().await;

    let res = app
        .post_json(
            "/exercises",
            &serde_json::json!({ "name": "Bench Press (Barbell) - Heavy!" }),
        )
        .await;
    assert_eq!(res.status(), 201);

    let exercise: serde_json::Value = res.json().await.unwrap();
    assert_eq!(exercise["name"], "Bench Press (Barbell) - Heavy!");
}

#[tokio::test]
async fn exercise_name_with_unicode() {
    let app = TestApp::spawn().await;

    let res = app
        .post_json(
            "/exercises",
            &serde_json::json!({ "name": "Übung mit Gewicht" }),
        )
        .await;
    assert_eq!(res.status(), 201);

    let exercise: serde_json::Value = res.json().await.unwrap();
    assert_eq!(exercise["name"], "Übung mit Gewicht");
}

#[tokio::test]
async fn exercise_name_with_emoji() {
    let app = TestApp::spawn().await;

    let res = app
        .post_json("/exercises", &serde_json::json!({ "name": "Deadlift 💪" }))
        .await;
    assert_eq!(res.status(), 201);

    let exercise: serde_json::Value = res.json().await.unwrap();
    assert_eq!(exercise["name"], "Deadlift 💪");
}

#[tokio::test]
async fn exercise_with_empty_name_fails() {
    let app = TestApp::spawn().await;

    let res = app
        .post_json("/exercises", &serde_json::json!({ "name": "" }))
        .await;
    // Empty name should return 400 Bad Request
    assert_eq!(res.status(), 400);
}

#[tokio::test]
async fn exercise_with_very_long_name() {
    let app = TestApp::spawn().await;
    let long_name = "A".repeat(500);

    let res = app
        .post_json("/exercises", &serde_json::json!({ "name": long_name }))
        .await;
    assert_eq!(res.status(), 201);

    let exercise: serde_json::Value = res.json().await.unwrap();
    assert_eq!(exercise["name"].as_str().unwrap().len(), 500);
}

#[tokio::test]
async fn exercise_with_whitespace_only_name_fails() {
    let app = TestApp::spawn().await;

    let res = app
        .post_json("/exercises", &serde_json::json!({ "name": "   " }))
        .await;
    // Whitespace-only name should return 400 Bad Request
    assert_eq!(res.status(), 400);
}

#[tokio::test]
async fn exercise_update_with_empty_body() {
    let app = TestApp::spawn().await;
    let exercise = app.create_exercise("Test Exercise").await;
    let id = exercise["id"].as_i64().unwrap();

    // Update with no fields should return the existing exercise
    let res = app
        .patch(&format!("/exercises/{}", id), serde_json::json!({}))
        .await;
    assert_eq!(res.status(), 200);

    let updated: serde_json::Value = res.json().await.unwrap();
    assert_eq!(updated["name"], "Test Exercise");
}

// ── Workout Set Edge Cases ──────────────────────────────────────────────────

#[tokio::test]
async fn set_with_zero_weight() {
    let app = TestApp::spawn().await;
    let workout = app.create_workout().await;
    let exercise = app.create_exercise("Bodyweight Squat").await;

    let workout_id = workout["id"].as_i64().unwrap();
    let exercise_id = exercise["id"].as_i64().unwrap();

    let set = app.add_set(workout_id, exercise_id, 1, 10, 0.0).await;
    assert_eq!(set["weight_kg"], 0.0);
}

#[tokio::test]
async fn set_with_zero_reps() {
    let app = TestApp::spawn().await;
    let workout = app.create_workout().await;
    let exercise = app.create_exercise("Failed Attempt").await;

    let workout_id = workout["id"].as_i64().unwrap();
    let exercise_id = exercise["id"].as_i64().unwrap();

    // Zero reps is technically valid (failed set)
    let set = app.add_set(workout_id, exercise_id, 1, 0, 100.0).await;
    assert_eq!(set["reps"], 0);
}

#[tokio::test]
async fn set_with_very_heavy_weight() {
    let app = TestApp::spawn().await;
    let workout = app.create_workout().await;
    let exercise = app.create_exercise("World Record Deadlift").await;

    let workout_id = workout["id"].as_i64().unwrap();
    let exercise_id = exercise["id"].as_i64().unwrap();

    let set = app.add_set(workout_id, exercise_id, 1, 1, 501.0).await;
    assert_eq!(set["weight_kg"], 501.0);
}

#[tokio::test]
async fn set_with_high_rep_count() {
    let app = TestApp::spawn().await;
    let workout = app.create_workout().await;
    let exercise = app.create_exercise("Pushups").await;

    let workout_id = workout["id"].as_i64().unwrap();
    let exercise_id = exercise["id"].as_i64().unwrap();

    let set = app.add_set(workout_id, exercise_id, 1, 1000, 0.0).await;
    assert_eq!(set["reps"], 1000);
}

#[tokio::test]
async fn set_with_decimal_weight() {
    let app = TestApp::spawn().await;
    let workout = app.create_workout().await;
    let exercise = app.create_exercise("Dumbbell Curl").await;

    let workout_id = workout["id"].as_i64().unwrap();
    let exercise_id = exercise["id"].as_i64().unwrap();

    let set = app.add_set(workout_id, exercise_id, 1, 12, 7.5).await;
    assert_eq!(set["weight_kg"], 7.5);
}

#[tokio::test]
async fn set_with_precise_decimal_weight() {
    let app = TestApp::spawn().await;
    let workout = app.create_workout().await;
    let exercise = app.create_exercise("Precise Exercise").await;

    let workout_id = workout["id"].as_i64().unwrap();
    let exercise_id = exercise["id"].as_i64().unwrap();

    let set = app.add_set(workout_id, exercise_id, 1, 10, 12.345).await;
    // Floating point comparison
    let weight = set["weight_kg"].as_f64().unwrap();
    assert!((weight - 12.345).abs() < 0.001);
}

#[tokio::test]
async fn multiple_sets_same_exercise_in_workout() {
    let app = TestApp::spawn().await;
    let workout = app.create_workout().await;
    let exercise = app.create_exercise("Bench Press").await;

    let workout_id = workout["id"].as_i64().unwrap();
    let exercise_id = exercise["id"].as_i64().unwrap();

    // Add 5 sets of the same exercise
    for i in 1..=5 {
        let set = app
            .add_set(workout_id, exercise_id, i, 10, 100.0 + (i as f64 * 5.0))
            .await;
        assert_eq!(set["set_number"], i);
    }

    // Verify all sets are in the workout
    let res = app.get(&format!("/workouts/{}", workout_id)).await;
    let workout_detail: serde_json::Value = res.json().await.unwrap();
    assert_eq!(workout_detail["sets"].as_array().unwrap().len(), 5);
}

// ── Weight Entry Edge Cases ─────────────────────────────────────────────────

#[tokio::test]
async fn weight_entry_with_precise_decimal() {
    let app = TestApp::spawn().await;

    let res = app
        .post_json("/weight", &serde_json::json!({ "weight_kg": 75.35 }))
        .await;
    assert_eq!(res.status(), 201);

    let entry: serde_json::Value = res.json().await.unwrap();
    let weight = entry["weight_kg"].as_f64().unwrap();
    assert!((weight - 75.35).abs() < 0.001);
}

#[tokio::test]
async fn weight_entry_with_zero_weight() {
    let app = TestApp::spawn().await;

    let res = app
        .post_json("/weight", &serde_json::json!({ "weight_kg": 0.0 }))
        .await;
    // Zero weight is rejected with 400 BAD_REQUEST
    assert_eq!(res.status(), 400);
}

#[tokio::test]
async fn weight_entry_with_very_high_weight() {
    let app = TestApp::spawn().await;

    let res = app
        .post_json("/weight", &serde_json::json!({ "weight_kg": 500.0 }))
        .await;
    assert_eq!(res.status(), 201);
}

#[tokio::test]
async fn weight_entry_with_custom_future_timestamp() {
    let app = TestApp::spawn().await;

    let res = app
        .post_json(
            "/weight",
            &serde_json::json!({
                "weight_kg": 75.0,
                "measured_at": "2030-01-01T00:00:00Z"
            }),
        )
        .await;
    assert_eq!(res.status(), 201);

    let entry: serde_json::Value = res.json().await.unwrap();
    assert_eq!(entry["measured_at"], "2030-01-01T00:00:00Z");
}

#[tokio::test]
async fn weight_entry_with_past_timestamp() {
    let app = TestApp::spawn().await;

    let res = app
        .post_json(
            "/weight",
            &serde_json::json!({
                "weight_kg": 80.0,
                "measured_at": "2020-06-15T10:30:00Z"
            }),
        )
        .await;
    assert_eq!(res.status(), 201);
}

// ── Workout State Transitions ───────────────────────────────────────────────

#[tokio::test]
async fn workout_can_be_finished_immediately() {
    let app = TestApp::spawn().await;
    let workout = app.create_workout().await;
    let id = workout["id"].as_i64().unwrap();

    // Finish without adding any sets
    let res = app.patch_empty(&format!("/workouts/{}/finish", id)).await;
    assert_eq!(res.status(), 204);
}

#[tokio::test]
async fn workout_restart_then_finish_again() {
    let app = TestApp::spawn().await;
    let workout = app.create_workout().await;
    let id = workout["id"].as_i64().unwrap();

    // Finish
    app.patch_empty(&format!("/workouts/{}/finish", id)).await;

    // Restart
    let res = app.patch_empty(&format!("/workouts/{}/restart", id)).await;
    assert_eq!(res.status(), 204);

    // Finish again
    let res = app.patch_empty(&format!("/workouts/{}/finish", id)).await;
    assert_eq!(res.status(), 204);
}

#[tokio::test]
async fn cannot_add_set_to_nonexistent_workout() {
    let app = TestApp::spawn().await;
    let exercise = app.create_exercise("Test").await;
    let exercise_id = exercise["id"].as_i64().unwrap();

    let res = app
        .post_json(
            "/workouts/99999/sets",
            &serde_json::json!({
                "exercise_id": exercise_id,
                "set_number": 1,
                "reps": 10,
                "weight_kg": 100.0,
            }),
        )
        .await;
    // Should fail with foreign key constraint or 404
    assert!(res.status() == 404 || res.status() == 500);
}

#[tokio::test]
async fn cannot_add_set_with_nonexistent_exercise() {
    let app = TestApp::spawn().await;
    let workout = app.create_workout().await;
    let workout_id = workout["id"].as_i64().unwrap();

    let res = app
        .post_json(
            &format!("/workouts/{}/sets", workout_id),
            &serde_json::json!({
                "exercise_id": 99999,
                "set_number": 1,
                "reps": 10,
                "weight_kg": 100.0,
            }),
        )
        .await;
    // Should fail with foreign key constraint
    assert!(res.status() == 404 || res.status() == 500);
}

// ── Deletion Cascading ──────────────────────────────────────────────────────

#[tokio::test]
async fn deleting_workout_removes_its_sets() {
    let app = TestApp::spawn().await;
    let workout = app.create_workout().await;
    let exercise = app.create_exercise("Test").await;

    let workout_id = workout["id"].as_i64().unwrap();
    let exercise_id = exercise["id"].as_i64().unwrap();

    // Add sets
    app.add_set(workout_id, exercise_id, 1, 10, 100.0).await;
    app.add_set(workout_id, exercise_id, 2, 10, 100.0).await;

    // Delete workout
    let res = app.delete(&format!("/workouts/{}", workout_id)).await;
    assert_eq!(res.status(), 204);

    // Workout should be gone
    let res = app.get(&format!("/workouts/{}", workout_id)).await;
    assert_eq!(res.status(), 404);
}

// ── Concurrent-like Operations ──────────────────────────────────────────────

#[tokio::test]
async fn rapid_workout_creation() {
    let app = TestApp::spawn().await;

    // Create many workouts rapidly
    for _ in 0..20 {
        let res = app.post_empty("/workouts").await;
        assert_eq!(res.status(), 201);
    }

    let res = app.get("/workouts").await;
    let workouts: Vec<serde_json::Value> = res.json().await.unwrap();
    assert_eq!(workouts.len(), 20);
}

#[tokio::test]
async fn rapid_set_addition() {
    let app = TestApp::spawn().await;
    let workout = app.create_workout().await;
    let exercise = app.create_exercise("Speed Test").await;

    let workout_id = workout["id"].as_i64().unwrap();
    let exercise_id = exercise["id"].as_i64().unwrap();

    // Add many sets rapidly
    for i in 1..=50 {
        app.add_set(workout_id, exercise_id, i, 10, 100.0).await;
    }

    let res = app.get(&format!("/workouts/{}", workout_id)).await;
    let detail: serde_json::Value = res.json().await.unwrap();
    assert_eq!(detail["sets"].as_array().unwrap().len(), 50);
}

// ── Malformed Requests ──────────────────────────────────────────────────────

#[tokio::test]
async fn exercise_with_missing_name_field() {
    let app = TestApp::spawn().await;

    let res = app
        .post_json("/exercises", &serde_json::json!({ "notes": "Some notes" }))
        .await;
    assert_eq!(res.status(), 422);
}

#[tokio::test]
async fn set_with_missing_required_fields() {
    let app = TestApp::spawn().await;
    let workout = app.create_workout().await;
    let workout_id = workout["id"].as_i64().unwrap();

    let res = app
        .post_json(
            &format!("/workouts/{}/sets", workout_id),
            &serde_json::json!({
                "reps": 10,
                // Missing exercise_id, set_number, weight_kg
            }),
        )
        .await;
    assert_eq!(res.status(), 422);
}

#[tokio::test]
async fn weight_entry_with_wrong_type() {
    let app = TestApp::spawn().await;

    let res = app
        .post_json(
            "/weight",
            &serde_json::json!({ "weight_kg": "not a number" }),
        )
        .await;
    assert_eq!(res.status(), 422);
}

// ── Exercise with Equipment ─────────────────────────────────────────────────

#[tokio::test]
async fn exercise_with_equipment_field() {
    let app = TestApp::spawn().await;

    let res = app
        .post_json(
            "/exercises",
            &serde_json::json!({
                "name": "Bench Press",
                "equipment": "Barbell"
            }),
        )
        .await;
    assert_eq!(res.status(), 201);

    let exercise: serde_json::Value = res.json().await.unwrap();
    assert_eq!(exercise["equipment"], "Barbell");
}

#[tokio::test]
async fn exercise_with_muscle_group() {
    let app = TestApp::spawn().await;

    let res = app
        .post_json(
            "/exercises",
            &serde_json::json!({
                "name": "Squat",
                "muscle_group": "Legs"
            }),
        )
        .await;
    assert_eq!(res.status(), 201);

    let exercise: serde_json::Value = res.json().await.unwrap();
    assert_eq!(exercise["muscle_group"], "Legs");
}

#[tokio::test]
async fn exercise_with_all_optional_fields() {
    let app = TestApp::spawn().await;

    let res = app
        .post_json(
            "/exercises",
            &serde_json::json!({
                "name": "Complete Exercise",
                "notes": "Detailed instructions here",
                "muscle_group": "Full Body",
                "equipment": "Kettlebell"
            }),
        )
        .await;
    assert_eq!(res.status(), 201);

    let exercise: serde_json::Value = res.json().await.unwrap();
    assert_eq!(exercise["name"], "Complete Exercise");
    assert_eq!(exercise["notes"], "Detailed instructions here");
    assert_eq!(exercise["muscle_group"], "Full Body");
    assert_eq!(exercise["equipment"], "Kettlebell");
}
