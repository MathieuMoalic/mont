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
}
