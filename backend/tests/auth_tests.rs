mod common;

use serde_json::json;

#[tokio::test]
async fn healthz_returns_ok() {
    let app = common::TestApp::spawn().await;
    let res = app.get_public("/healthz").await;
    assert_eq!(res.status(), 200);
    let body = res.text().await.unwrap();
    assert!(body.contains("ok"));
}

#[tokio::test]
async fn version_returns_version_string() {
    let app = common::TestApp::spawn().await;
    let res = app.get_public("/version").await;
    assert_eq!(res.status(), 200);
    let body: serde_json::Value = res.json().await.unwrap();
    assert!(body["version"].as_str().is_some());
}

#[tokio::test]
async fn protected_route_without_token_returns_401() {
    let app = common::TestApp::spawn().await;
    let res = app.get_public("/exercises").await;
    assert_eq!(res.status(), 401);
}

#[tokio::test]
async fn protected_route_with_bad_token_returns_401() {
    let app = common::TestApp::spawn().await;
    let res = app
        .client
        .get(app.url("/exercises"))
        .bearer_auth("not.a.valid.token")
        .send()
        .await
        .unwrap();
    assert_eq!(res.status(), 401);
}

#[tokio::test]
async fn protected_route_with_valid_token_returns_200() {
    let app = common::TestApp::spawn().await;
    let res = app.get("/exercises").await;
    assert_eq!(res.status(), 200);
}

#[tokio::test]
async fn login_with_no_password_hash_configured_returns_503() {
    let app = common::TestApp::spawn().await; // no password hash
    let res = app
        .post_json_public("/auth/login", &json!({ "password": "anything" }))
        .await;
    assert_eq!(res.status(), 503);
}

#[tokio::test]
async fn login_with_wrong_password_returns_401() {
    let hash = common::hash_password("correctpassword");
    let app = common::TestApp::spawn_with_password_hash(hash).await;
    let res = app
        .post_json_public("/auth/login", &json!({ "password": "wrongpassword" }))
        .await;
    assert_eq!(res.status(), 401);
}

#[tokio::test]
async fn login_with_correct_password_returns_token() {
    let hash = common::hash_password("correctpassword");
    let app = common::TestApp::spawn_with_password_hash(hash).await;
    let res = app
        .post_json_public("/auth/login", &json!({ "password": "correctpassword" }))
        .await;
    assert_eq!(res.status(), 200);
    let body: serde_json::Value = res.json().await.unwrap();
    assert!(body["token"].as_str().is_some_and(|t| !t.is_empty()));
    assert!(
        body["refresh_token"]
            .as_str()
            .is_some_and(|t| !t.is_empty())
    );
}

#[tokio::test]
async fn refresh_with_valid_refresh_token_returns_new_access_token() {
    let hash = common::hash_password("correctpassword");
    let app = common::TestApp::spawn_with_password_hash(hash).await;

    // Login to get refresh token
    let login_res = app
        .post_json_public("/auth/login", &json!({ "password": "correctpassword" }))
        .await;
    let login_body: serde_json::Value = login_res.json().await.unwrap();
    let refresh_token = login_body["refresh_token"].as_str().unwrap();

    // Use refresh token to get new access token
    let res = app
        .post_json_public("/auth/refresh", &json!({ "refresh_token": refresh_token }))
        .await;
    assert_eq!(res.status(), 200);
    let body: serde_json::Value = res.json().await.unwrap();
    assert!(body["token"].as_str().is_some_and(|t| !t.is_empty()));
}

#[tokio::test]
async fn refresh_with_invalid_token_returns_401() {
    let app = common::TestApp::spawn().await;
    let res = app
        .post_json_public(
            "/auth/refresh",
            &json!({ "refresh_token": "invalid.token.here" }),
        )
        .await;
    assert_eq!(res.status(), 401);
}

#[tokio::test]
async fn refresh_with_access_token_returns_401() {
    let hash = common::hash_password("correctpassword");
    let app = common::TestApp::spawn_with_password_hash(hash).await;

    // Login to get access token
    let login_res = app
        .post_json_public("/auth/login", &json!({ "password": "correctpassword" }))
        .await;
    let login_body: serde_json::Value = login_res.json().await.unwrap();
    let access_token = login_body["token"].as_str().unwrap();

    // Try to use access token as refresh token - should fail
    let res = app
        .post_json_public("/auth/refresh", &json!({ "refresh_token": access_token }))
        .await;
    assert_eq!(res.status(), 401);
}

#[tokio::test]
async fn protected_route_with_refresh_token_returns_401() {
    let hash = common::hash_password("correctpassword");
    let app = common::TestApp::spawn_with_password_hash(hash).await;

    // Login to get refresh token
    let login_res = app
        .post_json_public("/auth/login", &json!({ "password": "correctpassword" }))
        .await;
    let login_body: serde_json::Value = login_res.json().await.unwrap();
    let refresh_token = login_body["refresh_token"].as_str().unwrap();

    // Try to use refresh token to access protected route - should fail
    let res = app
        .client
        .get(app.url("/exercises"))
        .bearer_auth(refresh_token)
        .send()
        .await
        .unwrap();
    assert_eq!(res.status(), 401);
}
