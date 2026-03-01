mod common;

#[tokio::test]
async fn list_templates_initially_empty() {
    let app = common::TestApp::spawn().await;
    let res = app.get("/templates").await;
    assert_eq!(res.status(), 200);
    let body: serde_json::Value = res.json().await.unwrap();
    assert_eq!(body, serde_json::json!([]));
}

#[tokio::test]
async fn create_template_returns_201() {
    let app = common::TestApp::spawn().await;
    let res = app
        .post_json(
            "/templates",
            &serde_json::json!({ "name": "Push Day", "sets": [] }),
        )
        .await;
    assert_eq!(res.status(), 201);
    let body: serde_json::Value = res.json().await.unwrap();
    assert!(body["id"].as_i64().is_some());
    assert_eq!(body["name"], "Push Day");
    assert_eq!(body["set_count"], 0);
}

#[tokio::test]
async fn create_template_with_sets() {
    let app = common::TestApp::spawn().await;
    let ex = app.create_exercise("Bench Press").await;
    let ex_id = ex["id"].as_i64().unwrap();

    let res = app
        .post_json(
            "/templates",
            &serde_json::json!({
                "name": "Push Day",
                "sets": [
                    { "exercise_id": ex_id, "set_number": 1, "target_reps": 10, "target_weight_kg": 60.0 },
                    { "exercise_id": ex_id, "set_number": 2, "target_reps": 8,  "target_weight_kg": 70.0 },
                ]
            }),
        )
        .await;
    assert_eq!(res.status(), 201);
    let body: serde_json::Value = res.json().await.unwrap();
    assert_eq!(body["set_count"], 2);
}

#[tokio::test]
async fn get_template_returns_detail_with_sets() {
    let app = common::TestApp::spawn().await;
    let ex = app.create_exercise("Squat").await;
    let ex_id = ex["id"].as_i64().unwrap();

    let created: serde_json::Value = app
        .post_json(
            "/templates",
            &serde_json::json!({
                "name": "Leg Day",
                "sets": [
                    { "exercise_id": ex_id, "set_number": 1, "target_reps": 5, "target_weight_kg": 100.0 },
                ]
            }),
        )
        .await
        .json()
        .await
        .unwrap();
    let t_id = created["id"].as_i64().unwrap();

    let detail: serde_json::Value = app
        .get(&format!("/templates/{t_id}"))
        .await
        .json()
        .await
        .unwrap();
    assert_eq!(detail["name"], "Leg Day");
    assert_eq!(detail["sets"].as_array().unwrap().len(), 1);
    assert_eq!(detail["sets"][0]["exercise_name"], "Squat");
    assert_eq!(detail["sets"][0]["target_reps"], 5);
    assert_eq!(detail["sets"][0]["target_weight_kg"], 100.0);
}

#[tokio::test]
async fn get_nonexistent_template_returns_404() {
    let app = common::TestApp::spawn().await;
    let res = app.get("/templates/999").await;
    assert_eq!(res.status(), 404);
}

#[tokio::test]
async fn delete_template_returns_204() {
    let app = common::TestApp::spawn().await;
    let created: serde_json::Value = app
        .post_json("/templates", &serde_json::json!({ "name": "Temp", "sets": [] }))
        .await
        .json()
        .await
        .unwrap();
    let id = created["id"].as_i64().unwrap();

    let del = app.delete(&format!("/templates/{id}")).await;
    assert_eq!(del.status(), 204);

    let get = app.get(&format!("/templates/{id}")).await;
    assert_eq!(get.status(), 404);
}

#[tokio::test]
async fn delete_nonexistent_template_returns_404() {
    let app = common::TestApp::spawn().await;
    let res = app.delete("/templates/999").await;
    assert_eq!(res.status(), 404);
}

#[tokio::test]
async fn delete_template_cascades_to_sets() {
    let app = common::TestApp::spawn().await;
    let ex = app.create_exercise("Pull-up").await;
    let ex_id = ex["id"].as_i64().unwrap();

    let created: serde_json::Value = app
        .post_json(
            "/templates",
            &serde_json::json!({
                "name": "Pull Day",
                "sets": [
                    { "exercise_id": ex_id, "set_number": 1, "target_reps": 10, "target_weight_kg": 0.0 },
                ]
            }),
        )
        .await
        .json()
        .await
        .unwrap();
    let id = created["id"].as_i64().unwrap();

    app.delete(&format!("/templates/{id}")).await;
    // After deletion the template is gone; no orphan sets should remain (cascade)
    let res = app.get(&format!("/templates/{id}")).await;
    assert_eq!(res.status(), 404);
}

#[tokio::test]
async fn apply_template_adds_sets_to_workout() {
    let app = common::TestApp::spawn().await;
    let ex = app.create_exercise("Curl").await;
    let ex_id = ex["id"].as_i64().unwrap();

    let tmpl: serde_json::Value = app
        .post_json(
            "/templates",
            &serde_json::json!({
                "name": "Arms",
                "sets": [
                    { "exercise_id": ex_id, "set_number": 1, "target_reps": 12, "target_weight_kg": 15.0 },
                    { "exercise_id": ex_id, "set_number": 2, "target_reps": 10, "target_weight_kg": 17.5 },
                ]
            }),
        )
        .await
        .json()
        .await
        .unwrap();
    let t_id = tmpl["id"].as_i64().unwrap();

    let workout = app.create_workout().await;
    let w_id = workout["id"].as_i64().unwrap();

    let apply = app
        .post_empty(&format!("/templates/{t_id}/apply/{w_id}"))
        .await;
    assert_eq!(apply.status(), 204);

    let detail: serde_json::Value = app
        .get(&format!("/workouts/{w_id}"))
        .await
        .json()
        .await
        .unwrap();
    let sets = detail["sets"].as_array().unwrap();
    assert_eq!(sets.len(), 2);
    assert_eq!(sets[0]["reps"], 12);
    assert_eq!(sets[0]["weight_kg"], 15.0);
    assert_eq!(sets[1]["reps"], 10);
    assert_eq!(sets[1]["weight_kg"], 17.5);
}

#[tokio::test]
async fn apply_nonexistent_template_returns_404() {
    let app = common::TestApp::spawn().await;
    let workout = app.create_workout().await;
    let w_id = workout["id"].as_i64().unwrap();
    let res = app.post_empty(&format!("/templates/999/apply/{w_id}")).await;
    assert_eq!(res.status(), 404);
}

#[tokio::test]
async fn apply_template_to_nonexistent_workout_returns_404() {
    let app = common::TestApp::spawn().await;
    let ex = app.create_exercise("Press").await;
    let ex_id = ex["id"].as_i64().unwrap();
    let tmpl: serde_json::Value = app
        .post_json(
            "/templates",
            &serde_json::json!({
                "name": "T",
                "sets": [{ "exercise_id": ex_id, "set_number": 1, "target_reps": 5, "target_weight_kg": 50.0 }]
            }),
        )
        .await
        .json()
        .await
        .unwrap();
    let t_id = tmpl["id"].as_i64().unwrap();
    let res = app.post_empty(&format!("/templates/{t_id}/apply/9999")).await;
    assert_eq!(res.status(), 404);
}

#[tokio::test]
async fn list_templates_shows_created_template() {
    let app = common::TestApp::spawn().await;
    app.post_json("/templates", &serde_json::json!({ "name": "Push Day", "sets": [] }))
        .await;
    app.post_json("/templates", &serde_json::json!({ "name": "Pull Day", "sets": [] }))
        .await;

    let body: Vec<serde_json::Value> = app.get("/templates").await.json().await.unwrap();
    assert_eq!(body.len(), 2);
    // Sorted alphabetically
    assert_eq!(body[0]["name"], "Pull Day");
    assert_eq!(body[1]["name"], "Push Day");
}

#[tokio::test]
async fn create_template_without_name_returns_422() {
    let app = common::TestApp::spawn().await;
    let res = app
        .post_json("/templates", &serde_json::json!({ "sets": [] }))
        .await;
    assert_eq!(res.status(), 422);
}
