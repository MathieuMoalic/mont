mod common;

use base64::Engine;

const PNG_1X1_BASE64: &str =
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl6N2QAAAAASUVORK5CYII=";

#[tokio::test]
async fn issues_create_and_list_work() {
    let app = common::TestApp::spawn().await;

    let created = app
        .post_json(
            "/issues",
            &serde_json::json!({
                "message": "E2E issue report",
                "client_version": "0.8.3-test",
                "platform": "web",
                "route": "/calories"
            }),
        )
        .await;
    assert_eq!(created.status(), 201);

    let list = app.get("/issues?limit=20&offset=0").await;
    assert_eq!(list.status(), 200);
    let body: Vec<serde_json::Value> = list.json().await.unwrap();
    assert_eq!(body.len(), 1);
    assert_eq!(body[0]["message"], "E2E issue report");
}

#[tokio::test]
async fn body_pictures_upload_list_get_delete_round_trip() {
    let app = common::TestApp::spawn().await;

    let health = app.get("/health/daily?limit=20&offset=0").await;
    assert_eq!(health.status(), 200);

    let upload = app
        .post_json(
            "/health/pictures",
            &serde_json::json!({
                "picture_date": "2026-07-19",
                "picture_data": PNG_1X1_BASE64
            }),
        )
        .await;
    assert_eq!(upload.status(), 201);

    let list = app
        .get("/health/pictures?from=2026-07-01&to=2026-07-31")
        .await;
    assert_eq!(list.status(), 200);
    let pics: Vec<serde_json::Value> = list.json().await.unwrap();
    assert_eq!(pics.len(), 1);
    assert_eq!(pics[0]["picture_date"], "2026-07-19");

    let get = app.get("/health/pictures/2026-07-19").await;
    assert_eq!(get.status(), 200);
    let pic: serde_json::Value = get.json().await.unwrap();
    assert_eq!(pic["picture_date"], "2026-07-19");
    assert!(pic["picture_data"].as_str().is_some_and(|v| !v.is_empty()));
    let decoded = base64::engine::general_purpose::STANDARD
        .decode(pic["picture_data"].as_str().unwrap())
        .unwrap();
    assert!(!decoded.is_empty());

    let del = app.delete("/health/pictures/2026-07-19").await;
    assert_eq!(del.status(), 204);

    let missing = app.get("/health/pictures/2026-07-19").await;
    assert_eq!(missing.status(), 404);
}

#[tokio::test]
async fn meals_crud_and_log_flow_works() {
    let app = common::TestApp::spawn().await;

    let food_res = app
        .post_json(
            "/calories/foods",
            &serde_json::json!({
                "name": "Chicken breast",
                "brand": "test",
                "protein_per_100g": 31.0,
                "carbs_per_100g": 0.0,
                "fats_per_100g": 3.0,
                "last_weight_g": 120.0,
                "source": "manual"
            }),
        )
        .await;
    assert_eq!(food_res.status(), 201);
    let food: serde_json::Value = food_res.json().await.unwrap();
    let food_id = food["id"].as_i64().unwrap();

    let created = app
        .post_json(
            "/meals",
            &serde_json::json!({
                "name": "Chicken meal",
                "ingredients": [
                    { "food_id": food_id, "grams": 120.0 }
                ]
            }),
        )
        .await;
    assert_eq!(created.status(), 201);
    let meal: serde_json::Value = created.json().await.unwrap();
    let meal_id = meal["id"].as_i64().unwrap();
    assert_eq!(meal["name"], "Chicken meal");

    let list = app.get("/meals?limit=20&offset=0").await;
    assert_eq!(list.status(), 200);
    let meals: Vec<serde_json::Value> = list.json().await.unwrap();
    assert_eq!(meals.len(), 1);

    let get = app.get(&format!("/meals/{meal_id}")).await;
    assert_eq!(get.status(), 200);
    let detail: serde_json::Value = get.json().await.unwrap();
    assert_eq!(detail["ingredients"].as_array().unwrap().len(), 1);

    let update = app
        .patch(
            &format!("/meals/{meal_id}"),
            serde_json::json!({
                "name": "Updated chicken meal",
                "ingredients": [{ "food_id": food_id, "grams": 150.0 }]
            }),
        )
        .await;
    assert_eq!(update.status(), 200);
    let updated: serde_json::Value = update.json().await.unwrap();
    assert_eq!(updated["name"], "Updated chicken meal");

    let log = app
        .post_json(
            "/meals/log",
            &serde_json::json!({
                "day": "2026-07-19",
                "meal_period": "morning",
                "meal_id": meal_id,
                "percent": 80.0
            }),
        )
        .await;
    assert_eq!(log.status(), 201);

    let calories = app.get("/calories?start=2026-07-19&end=2026-07-19").await;
    assert_eq!(calories.status(), 200);
    let entries: Vec<serde_json::Value> = calories.json().await.unwrap();
    assert_eq!(entries.len(), 1);
    assert_eq!(entries[0]["meal_period"], "morning");

    let del = app.delete(&format!("/meals/{meal_id}")).await;
    assert_eq!(del.status(), 204);
}

#[tokio::test]
async fn meals_name_must_be_unique() {
    let app = common::TestApp::spawn().await;

    let food_res = app
        .post_json(
            "/calories/foods",
            &serde_json::json!({
                "name": "Tofu",
                "brand": "test",
                "protein_per_100g": 12.0,
                "carbs_per_100g": 2.0,
                "fats_per_100g": 6.0,
                "last_weight_g": 100.0,
                "source": "manual"
            }),
        )
        .await;
    assert_eq!(food_res.status(), 201);
    let food: serde_json::Value = food_res.json().await.unwrap();
    let food_id = food["id"].as_i64().unwrap();

    let first = app
        .post_json(
            "/meals",
            &serde_json::json!({
                "name": "Tofu bowl",
                "ingredients": [{ "food_id": food_id, "grams": 120.0 }]
            }),
        )
        .await;
    assert_eq!(first.status(), 201);
    let first_meal: serde_json::Value = first.json().await.unwrap();
    let first_id = first_meal["id"].as_i64().unwrap();

    let duplicate = app
        .post_json(
            "/meals",
            &serde_json::json!({
                "name": "  tofu bowl  ",
                "ingredients": [{ "food_id": food_id, "grams": 120.0 }]
            }),
        )
        .await;
    assert_eq!(duplicate.status(), 409);

    let second = app
        .post_json(
            "/meals",
            &serde_json::json!({
                "name": "Tofu dinner",
                "ingredients": [{ "food_id": food_id, "grams": 90.0 }]
            }),
        )
        .await;
    assert_eq!(second.status(), 201);
    let second_meal: serde_json::Value = second.json().await.unwrap();
    let second_id = second_meal["id"].as_i64().unwrap();

    let rename_conflict = app
        .patch(
            &format!("/meals/{second_id}"),
            serde_json::json!({
                "name": "TOFU BOWL"
            }),
        )
        .await;
    assert_eq!(rename_conflict.status(), 409);

    let self_rename_ok = app
        .patch(
            &format!("/meals/{first_id}"),
            serde_json::json!({
                "name": " tofu bowl "
            }),
        )
        .await;
    assert_eq!(self_rename_ok.status(), 200);
}

#[tokio::test]
async fn barcode_and_lookup_endpoints_are_reachable() {
    let app = common::TestApp::spawn().await;
    let barcode = "1234567890123";

    let initial_get = app
        .get(&format!("/calories/foods/by-barcode/{barcode}"))
        .await;
    assert_eq!(initial_get.status(), 404);

    let upsert = app
        .put(
            &format!("/calories/foods/by-barcode/{barcode}"),
            serde_json::json!({
                "name": "Barcoded food",
                "brand": "test",
                "protein_per_100g": 10.0,
                "carbs_per_100g": 20.0,
                "fats_per_100g": 5.0,
                "last_weight_g": 100.0,
                "source": "manual"
            }),
        )
        .await;
    assert_eq!(upsert.status(), 200);

    let get_after = app
        .get(&format!("/calories/foods/by-barcode/{barcode}"))
        .await;
    assert_eq!(get_after.status(), 200);

    let invalid_lookup = app.get("/calories/foods/lookup/not-a-barcode").await;
    assert_eq!(invalid_lookup.status(), 400);

    let empty_query_lookup = app.get("/calories/foods/lookup?q=").await;
    assert_eq!(empty_query_lookup.status(), 400);

    let query_lookup = app.get("/calories/foods/lookup?q=barcoded").await;
    assert_eq!(query_lookup.status(), 200);

    let extract = app.get("/calories/foods/extract-macros?q=banana").await;
    assert_eq!(extract.status(), 503);

    let usda_search = app.get("/calories/foods/search-usda?q=banana").await;
    assert_eq!(usda_search.status(), 503);
}
