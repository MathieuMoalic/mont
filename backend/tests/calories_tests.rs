mod common;

#[tokio::test]
async fn list_calories_initially_empty() {
    let app = common::TestApp::spawn().await;
    let res = app.get("/calories?start=2026-01-01&end=2026-01-31").await;
    assert_eq!(res.status(), 200);
    let body: serde_json::Value = res.json().await.unwrap();
    assert_eq!(body, serde_json::json!([]));
}

#[tokio::test]
async fn create_calorie_entry_returns_201() {
    let app = common::TestApp::spawn().await;
    let res = app
        .post_json(
            "/calories",
            &serde_json::json!({
                "day": "2026-01-15",
                "meal_period": "morning",
                "name": "Oatmeal",
                "protein_per_100g": 12.0,
                "carbs_per_100g": 54.0,
                "fats_per_100g": 8.0,
                "weight_g": 100.0
            }),
        )
        .await;
    assert_eq!(res.status(), 201);
    let body: serde_json::Value = res.json().await.unwrap();
    assert_eq!(body["day"], "2026-01-15");
    assert_eq!(body["meal_period"], "morning");
    assert_eq!(body["name"], "Oatmeal");
    assert_eq!(body["kcal"], 336);
    assert_eq!(body["weight_g"], 100.0);
}

#[tokio::test]
async fn create_calorie_entry_with_invalid_meal_period_returns_400() {
    let app = common::TestApp::spawn().await;
    let res = app
        .post_json(
            "/calories",
            &serde_json::json!({
                "day": "2026-01-15",
                "meal_period": "night",
                "name": "Snack",
                "protein_per_100g": 5.0,
                "carbs_per_100g": 10.0,
                "fats_per_100g": 3.0,
                "weight_g": 100.0
            }),
        )
        .await;
    assert_eq!(res.status(), 400);
}

#[tokio::test]
async fn list_calories_filters_range_and_orders_meal_period() {
    let app = common::TestApp::spawn().await;

    let _ = app
        .post_json(
            "/calories",
            &serde_json::json!({
                "day": "2026-01-20",
                "meal_period": "evening",
                "name": "Dinner",
                "protein_per_100g": 40.0,
                "carbs_per_100g": 60.0,
                "fats_per_100g": 20.0,
                "weight_g": 100.0
            }),
        )
        .await;
    let _ = app
        .post_json(
            "/calories",
            &serde_json::json!({
                "day": "2026-01-20",
                "meal_period": "morning",
                "name": "Breakfast",
                "protein_per_100g": 20.0,
                "carbs_per_100g": 70.0,
                "fats_per_100g": 10.0,
                "weight_g": 100.0
            }),
        )
        .await;
    let _ = app
        .post_json(
            "/calories",
            &serde_json::json!({
                "day": "2026-02-01",
                "meal_period": "afternoon",
                "name": "Lunch",
                "protein_per_100g": 30.0,
                "carbs_per_100g": 50.0,
                "fats_per_100g": 15.0,
                "weight_g": 100.0
            }),
        )
        .await;

    let body: Vec<serde_json::Value> = app
        .get("/calories?start=2026-01-01&end=2026-01-31")
        .await
        .json()
        .await
        .unwrap();
    assert_eq!(body.len(), 2);
    assert_eq!(body[0]["meal_period"], "morning");
    assert_eq!(body[1]["meal_period"], "evening");
}

#[tokio::test]
async fn update_calorie_entry_updates_fields() {
    let app = common::TestApp::spawn().await;
    let created: serde_json::Value = app
        .post_json(
            "/calories",
            &serde_json::json!({
                "day": "2026-01-10",
                "meal_period": "afternoon",
                "name": "Lunch",
                "protein_per_100g": 25.0,
                "carbs_per_100g": 40.0,
                "fats_per_100g": 12.0,
                "weight_g": 100.0
            }),
        )
        .await
        .json()
        .await
        .unwrap();
    let id = created["id"].as_i64().unwrap();

    let res = app
        .patch(
            &format!("/calories/{id}"),
            serde_json::json!({
                "meal_period": "evening",
                "name": "Big dinner",
                "protein_per_100g": 30.0,
                "carbs_per_100g": 90.0,
                "fats_per_100g": 20.0,
                "weight_g": 150.0
            }),
        )
        .await;
    assert_eq!(res.status(), 200);
    let updated: serde_json::Value = res.json().await.unwrap();
    assert_eq!(updated["meal_period"], "evening");
    assert_eq!(updated["name"], "Big dinner");
    assert_eq!(updated["kcal"], 990);
}

#[tokio::test]
async fn delete_calorie_entry_returns_204_and_removes_it() {
    let app = common::TestApp::spawn().await;
    let created: serde_json::Value = app
        .post_json(
            "/calories",
            &serde_json::json!({
                "day": "2026-01-10",
                "meal_period": "morning",
                "name": "Eggs",
                "protein_per_100g": 14.0,
                "carbs_per_100g": 1.0,
                "fats_per_100g": 10.0,
                "weight_g": 100.0
            }),
        )
        .await
        .json()
        .await
        .unwrap();
    let id = created["id"].as_i64().unwrap();

    let res = app.delete(&format!("/calories/{id}")).await;
    assert_eq!(res.status(), 204);

    let body: Vec<serde_json::Value> = app
        .get("/calories?start=2026-01-01&end=2026-01-31")
        .await
        .json()
        .await
        .unwrap();
    assert!(body.is_empty());
}

#[tokio::test]
async fn nutrition_targets_round_trip() {
    let app = common::TestApp::spawn().await;
    let initial: serde_json::Value = app.get("/calories/targets").await.json().await.unwrap();
    assert_eq!(initial["protein_g"], 0.0);
    assert_eq!(initial["carbs_g"], 0.0);
    assert_eq!(initial["fats_g"], 0.0);

    let put = app
        .put(
            "/calories/targets",
            serde_json::json!({"protein_g": 180.0, "carbs_g": 260.0, "fats_g": 70.0}),
        )
        .await;
    assert_eq!(put.status(), 204);

    let updated: serde_json::Value = app.get("/calories/targets").await.json().await.unwrap();
    assert_eq!(updated["protein_g"], 180.0);
    assert_eq!(updated["carbs_g"], 260.0);
    assert_eq!(updated["fats_g"], 70.0);
}

#[tokio::test]
async fn calorie_exercises_crud() {
    let app = common::TestApp::spawn().await;

    let created: serde_json::Value = app
        .post_json(
            "/calories/exercises",
            &serde_json::json!({
                "day": "2026-01-10",
                "name": "Running",
                "kcal": 320
            }),
        )
        .await
        .json()
        .await
        .unwrap();
    let id = created["id"].as_i64().unwrap();
    assert_eq!(created["name"], "Running");

    let list: Vec<serde_json::Value> = app
        .get("/calories/exercises?start=2026-01-01&end=2026-01-31")
        .await
        .json()
        .await
        .unwrap();
    assert_eq!(list.len(), 1);

    let updated: serde_json::Value = app
        .patch(
            &format!("/calories/exercises/{id}"),
            serde_json::json!({
                "name": "Running intervals",
                "kcal": 400
            }),
        )
        .await
        .json()
        .await
        .unwrap();
    assert_eq!(updated["name"], "Running intervals");
    assert_eq!(updated["kcal"], 400);

    let del = app.delete(&format!("/calories/exercises/{id}")).await;
    assert_eq!(del.status(), 204);
}

#[tokio::test]
async fn creating_food_adds_saved_food_and_search_finds_it() {
    let app = common::TestApp::spawn().await;
    let _ = app
        .post_json(
            "/calories",
            &serde_json::json!({
                "day": "2026-01-11",
                "meal_period": "morning",
                "name": "Greek Yogurt",
                "protein_per_100g": 10.0,
                "carbs_per_100g": 4.0,
                "fats_per_100g": 5.0,
                "weight_g": 180.0
            }),
        )
        .await;

    let foods: Vec<serde_json::Value> = app
        .get("/calories/foods?q=Yogurt")
        .await
        .json()
        .await
        .unwrap();
    assert_eq!(foods.len(), 1);
    assert_eq!(foods[0]["name"], "Greek Yogurt");
    assert_eq!(foods[0]["last_weight_g"], 180.0);
}

#[tokio::test]
async fn updating_food_updates_saved_food_last_weight() {
    let app = common::TestApp::spawn().await;
    let created: serde_json::Value = app
        .post_json(
            "/calories",
            &serde_json::json!({
                "day": "2026-01-11",
                "meal_period": "morning",
                "name": "Rice",
                "protein_per_100g": 3.0,
                "carbs_per_100g": 28.0,
                "fats_per_100g": 0.3,
                "weight_g": 150.0
            }),
        )
        .await
        .json()
        .await
        .unwrap();
    let id = created["id"].as_i64().unwrap();

    let _ = app
        .patch(
            &format!("/calories/{id}"),
            serde_json::json!({"weight_g": 220.0}),
        )
        .await;

    let foods: Vec<serde_json::Value> = app
        .get("/calories/foods?q=Rice")
        .await
        .json()
        .await
        .unwrap();
    assert_eq!(foods.len(), 1);
    assert_eq!(foods[0]["last_weight_g"], 220.0);
}
