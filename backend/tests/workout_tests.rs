mod common;

// ── Workout CRUD ─────────────────────────────────────────────────────────────

#[tokio::test]
async fn list_workouts_initially_empty() {
    let app = common::TestApp::spawn().await;
    let body: serde_json::Value = app.get("/workouts").await.json().await.unwrap();
    assert_eq!(body, serde_json::json!([]));
}

#[tokio::test]
async fn create_workout_returns_201() {
    let app = common::TestApp::spawn().await;
    let res = app.post_empty("/workouts").await;
    assert_eq!(res.status(), 201);
}

#[tokio::test]
async fn created_workout_has_expected_fields() {
    let app = common::TestApp::spawn().await;
    let body: serde_json::Value = app.post_empty("/workouts").await.json().await.unwrap();
    assert!(body["id"].as_i64().is_some());
    assert!(body["started_at"].as_str().is_some());
    assert!(body["finished_at"].is_null());
    assert_eq!(body["set_count"], 0);
}

#[tokio::test]
async fn list_workouts_shows_created_workout() {
    let app = common::TestApp::spawn().await;
    app.create_workout().await;
    app.create_workout().await;

    let body: Vec<serde_json::Value> = app.get("/workouts").await.json().await.unwrap();
    assert_eq!(body.len(), 2);
}

#[tokio::test]
async fn get_workout_returns_detail() {
    let app = common::TestApp::spawn().await;
    let w = app.create_workout().await;
    let id = w["id"].as_i64().unwrap();

    let res = app.get(&format!("/workouts/{id}")).await;
    assert_eq!(res.status(), 200);
    let body: serde_json::Value = res.json().await.unwrap();
    assert_eq!(body["id"], id);
    assert!(body["sets"].as_array().unwrap().is_empty());
}

#[tokio::test]
async fn get_nonexistent_workout_returns_404() {
    let app = common::TestApp::spawn().await;
    let res = app.get("/workouts/9999").await;
    assert_eq!(res.status(), 404);
}

#[tokio::test]
async fn finish_workout_returns_204() {
    let app = common::TestApp::spawn().await;
    let w = app.create_workout().await;
    let id = w["id"].as_i64().unwrap();

    let res = app.patch_empty(&format!("/workouts/{id}/finish")).await;
    assert_eq!(res.status(), 204);
}

#[tokio::test]
async fn finish_workout_sets_finished_at() {
    let app = common::TestApp::spawn().await;
    let w = app.create_workout().await;
    let id = w["id"].as_i64().unwrap();

    app.patch_empty(&format!("/workouts/{id}/finish")).await;

    let body: serde_json::Value = app.get(&format!("/workouts/{id}")).await.json().await.unwrap();
    assert!(body["finished_at"].as_str().is_some());
}

#[tokio::test]
async fn finish_already_finished_workout_returns_404() {
    let app = common::TestApp::spawn().await;
    let w = app.create_workout().await;
    let id = w["id"].as_i64().unwrap();

    app.patch_empty(&format!("/workouts/{id}/finish")).await;
    let res = app.patch_empty(&format!("/workouts/{id}/finish")).await;
    assert_eq!(res.status(), 404);
}

// ── Sets ─────────────────────────────────────────────────────────────────────

#[tokio::test]
async fn add_set_returns_201_with_data() {
    let app = common::TestApp::spawn().await;
    let w = app.create_workout().await;
    let e = app.create_exercise("Bench Press").await;

    let res = app
        .post_json(
            &format!("/workouts/{}/sets", w["id"]),
            &serde_json::json!({
                "exercise_id": e["id"],
                "set_number": 1,
                "reps": 10,
                "weight_kg": 80.0,
            }),
        )
        .await;
    assert_eq!(res.status(), 201);
    let body: serde_json::Value = res.json().await.unwrap();
    assert!(body["id"].as_i64().is_some());
    assert_eq!(body["reps"], 10);
    assert_eq!(body["weight_kg"], 80.0);
    assert_eq!(body["set_number"], 1);
}

#[tokio::test]
async fn add_set_includes_exercise_name() {
    let app = common::TestApp::spawn().await;
    let w = app.create_workout().await;
    let e = app.create_exercise("Deadlift").await;

    let set = app.add_set(w["id"].as_i64().unwrap(), e["id"].as_i64().unwrap(), 1, 5, 140.0).await;
    assert_eq!(set["exercise_name"], "Deadlift");
}

#[tokio::test]
async fn get_workout_returns_sets() {
    let app = common::TestApp::spawn().await;
    let w = app.create_workout().await;
    let e = app.create_exercise("Squat").await;
    let wid = w["id"].as_i64().unwrap();
    let eid = e["id"].as_i64().unwrap();

    app.add_set(wid, eid, 1, 8, 100.0).await;
    app.add_set(wid, eid, 2, 8, 100.0).await;
    app.add_set(wid, eid, 3, 6, 105.0).await;

    let body: serde_json::Value = app.get(&format!("/workouts/{wid}")).await.json().await.unwrap();
    let sets = body["sets"].as_array().unwrap();
    assert_eq!(sets.len(), 3);
    assert_eq!(sets[2]["weight_kg"], 105.0);
}

#[tokio::test]
async fn list_workouts_reflects_set_count() {
    let app = common::TestApp::spawn().await;
    let w = app.create_workout().await;
    let e = app.create_exercise("Row").await;
    let wid = w["id"].as_i64().unwrap();
    let eid = e["id"].as_i64().unwrap();

    app.add_set(wid, eid, 1, 12, 60.0).await;
    app.add_set(wid, eid, 2, 12, 60.0).await;

    let workouts: Vec<serde_json::Value> = app.get("/workouts").await.json().await.unwrap();
    assert_eq!(workouts[0]["set_count"], 2);
}

#[tokio::test]
async fn delete_set_returns_204() {
    let app = common::TestApp::spawn().await;
    let w = app.create_workout().await;
    let e = app.create_exercise("Curl").await;
    let wid = w["id"].as_i64().unwrap();
    let eid = e["id"].as_i64().unwrap();

    let set = app.add_set(wid, eid, 1, 10, 20.0).await;
    let sid = set["id"].as_i64().unwrap();

    let res = app.delete(&format!("/workouts/{wid}/sets/{sid}")).await;
    assert_eq!(res.status(), 204);
}

#[tokio::test]
async fn delete_set_removes_it_from_workout() {
    let app = common::TestApp::spawn().await;
    let w = app.create_workout().await;
    let e = app.create_exercise("Tricep Extension").await;
    let wid = w["id"].as_i64().unwrap();
    let eid = e["id"].as_i64().unwrap();

    let set = app.add_set(wid, eid, 1, 15, 30.0).await;
    app.delete(&format!("/workouts/{wid}/sets/{}", set["id"])).await;

    let body: serde_json::Value = app.get(&format!("/workouts/{wid}")).await.json().await.unwrap();
    assert!(body["sets"].as_array().unwrap().is_empty());
}

#[tokio::test]
async fn delete_nonexistent_set_returns_404() {
    let app = common::TestApp::spawn().await;
    let w = app.create_workout().await;
    let wid = w["id"].as_i64().unwrap();
    let res = app.delete(&format!("/workouts/{wid}/sets/9999")).await;
    assert_eq!(res.status(), 404);
}

#[tokio::test]
async fn delete_set_from_wrong_workout_returns_404() {
    let app = common::TestApp::spawn().await;
    let w1 = app.create_workout().await;
    let w2 = app.create_workout().await;
    let e = app.create_exercise("Lunge").await;
    let w1id = w1["id"].as_i64().unwrap();
    let w2id = w2["id"].as_i64().unwrap();
    let eid = e["id"].as_i64().unwrap();

    let set = app.add_set(w1id, eid, 1, 12, 0.0).await;
    let sid = set["id"].as_i64().unwrap();

    // Try to delete set from workout 1 but via workout 2's URL
    let res = app.delete(&format!("/workouts/{w2id}/sets/{sid}")).await;
    assert_eq!(res.status(), 404);
}

#[tokio::test]
async fn add_set_with_fractional_weight() {
    let app = common::TestApp::spawn().await;
    let w = app.create_workout().await;
    let e = app.create_exercise("Lateral Raise").await;
    let wid = w["id"].as_i64().unwrap();
    let eid = e["id"].as_i64().unwrap();

    let set = app.add_set(wid, eid, 1, 15, 7.5).await;
    assert_eq!(set["weight_kg"], 7.5);
}

#[tokio::test]
async fn delete_workout_returns_204() {
    let app = common::TestApp::spawn().await;
    let w = app.create_workout().await;
    let wid = w["id"].as_i64().unwrap();
    let res = app.delete(&format!("/workouts/{wid}")).await;
    assert_eq!(res.status(), 204);
}

#[tokio::test]
async fn delete_workout_removes_it_from_list() {
    let app = common::TestApp::spawn().await;
    let w = app.create_workout().await;
    let wid = w["id"].as_i64().unwrap();
    app.delete(&format!("/workouts/{wid}")).await;
    let list: Vec<serde_json::Value> = app.get("/workouts").await.json().await.unwrap();
    assert!(list.iter().all(|x| x["id"] != wid));
}

#[tokio::test]
async fn delete_nonexistent_workout_returns_404() {
    let app = common::TestApp::spawn().await;
    let res = app.delete("/workouts/999").await;
    assert_eq!(res.status(), 404);
}

#[tokio::test]
async fn restart_workout_returns_204() {
    let app = common::TestApp::spawn().await;
    let w = app.create_workout().await;
    let wid = w["id"].as_i64().unwrap();
    app.patch_empty(&format!("/workouts/{wid}/finish")).await;
    let res = app.patch_empty(&format!("/workouts/{wid}/restart")).await;
    assert_eq!(res.status(), 204);
}

#[tokio::test]
async fn restart_workout_clears_finished_at() {
    let app = common::TestApp::spawn().await;
    let w = app.create_workout().await;
    let wid = w["id"].as_i64().unwrap();
    app.patch_empty(&format!("/workouts/{wid}/finish")).await;
    app.patch_empty(&format!("/workouts/{wid}/restart")).await;
    let detail: serde_json::Value = app.get(&format!("/workouts/{wid}")).await.json().await.unwrap();
    assert!(detail["finished_at"].is_null());
}

#[tokio::test]
async fn restart_active_workout_returns_404() {
    let app = common::TestApp::spawn().await;
    let w = app.create_workout().await;
    let wid = w["id"].as_i64().unwrap();
    let res = app.patch_empty(&format!("/workouts/{wid}/restart")).await;
    assert_eq!(res.status(), 404);
}
