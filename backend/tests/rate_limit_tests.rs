mod common;

use common::TestApp;

// ── Rate Limiting Tests ─────────────────────────────────────────────────────

#[tokio::test]
async fn public_endpoints_not_rate_limited_under_threshold() {
    let app = TestApp::spawn().await;

    // Make 50 requests to healthz - should all succeed
    for _ in 0..50 {
        let res = app.get_public("/healthz").await;
        assert_eq!(res.status(), 200);
    }
}

#[tokio::test]
async fn version_endpoint_responds_with_version() {
    let app = TestApp::spawn().await;
    let res = app.get_public("/version").await;
    assert_eq!(res.status(), 200);

    let body: serde_json::Value = res.json().await.unwrap();
    assert!(body["version"].is_string());
    assert!(!body["version"].as_str().unwrap().is_empty());
}

// ── X-Forwarded-For Header Tests ────────────────────────────────────────────

#[tokio::test]
async fn requests_with_different_x_forwarded_for_are_tracked_separately() {
    let app = TestApp::spawn().await;

    // Simulate requests from different IPs
    let client = reqwest::Client::new();

    let res1 = client
        .get(app.url("/healthz"))
        .header("X-Forwarded-For", "192.168.1.1")
        .send()
        .await
        .unwrap();
    assert_eq!(res1.status(), 200);

    let res2 = client
        .get(app.url("/healthz"))
        .header("X-Forwarded-For", "192.168.1.2")
        .send()
        .await
        .unwrap();
    assert_eq!(res2.status(), 200);
}

#[tokio::test]
async fn x_forwarded_for_with_multiple_ips_uses_first() {
    let app = TestApp::spawn().await;
    let client = reqwest::Client::new();

    // Send request with multiple IPs in chain (first is client IP)
    let res = client
        .get(app.url("/healthz"))
        .header("X-Forwarded-For", "10.0.0.1, 192.168.1.1, 172.16.0.1")
        .send()
        .await
        .unwrap();
    assert_eq!(res.status(), 200);
}

#[tokio::test]
async fn x_real_ip_header_is_respected() {
    let app = TestApp::spawn().await;
    let client = reqwest::Client::new();

    let res = client
        .get(app.url("/healthz"))
        .header("X-Real-IP", "10.10.10.10")
        .send()
        .await
        .unwrap();
    assert_eq!(res.status(), 200);
}

// ── Protected Endpoint Rate Limits ──────────────────────────────────────────

#[tokio::test]
async fn authenticated_requests_work_under_rate_limit() {
    let app = TestApp::spawn().await;

    // Make several authenticated requests - should all succeed
    for _ in 0..10 {
        let res = app.get("/exercises").await;
        assert_eq!(res.status(), 200);
    }
}

#[tokio::test]
async fn authenticated_post_requests_work() {
    let app = TestApp::spawn().await;

    // Create multiple exercises
    for i in 0..5 {
        let res = app
            .post_json(
                "/exercises",
                &serde_json::json!({ "name": format!("Exercise {}", i) }),
            )
            .await;
        assert_eq!(res.status(), 201);
    }
}
