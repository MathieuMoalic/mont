#![allow(dead_code)]

use std::path::PathBuf;

use jsonwebtoken::{Algorithm, EncodingKey, Header};
use mont::{app::build_app, config::Config, db::make_pool, models::AppState};
use serde::{Deserialize, Serialize};
use tokio::net::TcpListener;

const TEST_JWT_SECRET: &str = "test-jwt-secret-for-integration-tests!!";

#[derive(Serialize, Deserialize)]
struct Claims {
    sub: i64,
    exp: u64,
}

use sqlx::SqlitePool;

pub struct TestApp {
    pub client: reqwest::Client,
    pub base_url: String,
    pub token: String,
    pub pool: SqlitePool,
    // Kept alive so the temp file isn't deleted while the server is running.
    _db: tempfile::NamedTempFile,
}

impl TestApp {
    pub async fn spawn() -> Self {
        Self::spawn_inner(None).await
    }

    pub async fn spawn_with_password_hash(hash: String) -> Self {
        Self::spawn_inner(Some(hash)).await
    }

    async fn spawn_inner(password_hash: Option<String>) -> Self {
        let db = tempfile::NamedTempFile::new().expect("temp db");
        let pool = make_pool(db.path().to_str().unwrap().to_string())
            .await
            .expect("pool");

        let config = Config {
            verbose: 0,
            quiet: 0,
            bind: "127.0.0.1:0".parse().unwrap(),
            database_path: db.path().to_str().unwrap().to_string(),
            log_file: PathBuf::from("/dev/null"),
            cors_origin: None,
            jwt_secret: Some(TEST_JWT_SECRET.to_string()),
            password_hash,
            gadgetbridge_zip: None,
            gadgetbridge_db: None,
        };

        let pool2 = pool.clone();
        let state = AppState {
            pool,
            jwt_encoding: EncodingKey::from_secret(TEST_JWT_SECRET.as_bytes()),
            config,
        };

        let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind");
        let addr = listener.local_addr().unwrap();
        tokio::spawn(async move { axum::serve(listener, build_app(state)).await.unwrap() });

        let exp = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_secs()
            + 3600;
        let token = jsonwebtoken::encode(
            &Header::new(Algorithm::HS256),
            &Claims { sub: 1, exp },
            &EncodingKey::from_secret(TEST_JWT_SECRET.as_bytes()),
        )
        .unwrap();

        Self {
            client: reqwest::Client::new(),
            base_url: format!("http://{addr}"),
            token,
            pool: pool2,
            _db: db,
        }
    }

    pub fn url(&self, path: &str) -> String {
        format!("{}{}", self.base_url, path)
    }

    // ── Authenticated helpers ─────────────────────────────────────────────────

    pub async fn get(&self, path: &str) -> reqwest::Response {
        self.client
            .get(self.url(path))
            .bearer_auth(&self.token)
            .send()
            .await
            .unwrap()
    }

    pub async fn post_json(&self, path: &str, body: &serde_json::Value) -> reqwest::Response {
        self.client
            .post(self.url(path))
            .bearer_auth(&self.token)
            .json(body)
            .send()
            .await
            .unwrap()
    }

    pub async fn post_empty(&self, path: &str) -> reqwest::Response {
        self.client
            .post(self.url(path))
            .bearer_auth(&self.token)
            .header(reqwest::header::CONTENT_LENGTH, "0")
            .send()
            .await
            .unwrap()
    }

    pub async fn patch_empty(&self, path: &str) -> reqwest::Response {
        self.client
            .patch(self.url(path))
            .bearer_auth(&self.token)
            .header(reqwest::header::CONTENT_LENGTH, "0")
            .send()
            .await
            .unwrap()
    }

    pub async fn patch(&self, path: &str, body: serde_json::Value) -> reqwest::Response {
        self.client
            .patch(self.url(path))
            .bearer_auth(&self.token)
            .json(&body)
            .send()
            .await
            .unwrap()
    }

    pub async fn delete(&self, path: &str) -> reqwest::Response {
        self.client
            .delete(self.url(path))
            .bearer_auth(&self.token)
            .send()
            .await
            .unwrap()
    }

    // ── Unauthenticated helpers ───────────────────────────────────────────────

    pub async fn get_public(&self, path: &str) -> reqwest::Response {
        self.client.get(self.url(path)).send().await.unwrap()
    }

    pub async fn post_json_public(&self, path: &str, body: &serde_json::Value) -> reqwest::Response {
        self.client
            .post(self.url(path))
            .json(body)
            .send()
            .await
            .unwrap()
    }

    // ── Domain shortcuts ──────────────────────────────────────────────────────

    pub async fn create_exercise(&self, name: &str) -> serde_json::Value {
        self.post_json("/exercises", &serde_json::json!({ "name": name }))
            .await
            .json()
            .await
            .unwrap()
    }

    pub async fn create_workout(&self) -> serde_json::Value {
        self.post_empty("/workouts").await.json().await.unwrap()
    }

    pub async fn add_set(
        &self,
        workout_id: i64,
        exercise_id: i64,
        set_number: i64,
        reps: i64,
        weight_kg: f64,
    ) -> serde_json::Value {
        self.post_json(
            &format!("/workouts/{workout_id}/sets"),
            &serde_json::json!({
                "exercise_id": exercise_id,
                "set_number": set_number,
                "reps": reps,
                "weight_kg": weight_kg,
            }),
        )
        .await
        .json()
        .await
        .unwrap()
    }
}

pub fn hash_password(password: &str) -> String {
    use argon2::password_hash::{PasswordHasher, SaltString};
    use argon2::Argon2;
    use rand::rngs::OsRng;
    let salt = SaltString::generate(&mut OsRng);
    Argon2::default()
        .hash_password(password.as_bytes(), &salt)
        .unwrap()
        .to_string()
}
