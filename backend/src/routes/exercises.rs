use axum::{extract::State, http::StatusCode, Json};
use serde::{Deserialize, Serialize};

use crate::{error::AppResult, models::AppState};

#[derive(Serialize, sqlx::FromRow)]
pub struct Exercise {
    pub id: i64,
    pub name: String,
    pub notes: Option<String>,
}

#[derive(Deserialize)]
pub struct CreateExercise {
    pub name: String,
    pub notes: Option<String>,
}

pub async fn list_exercises(State(state): State<AppState>) -> AppResult<Json<Vec<Exercise>>> {
    let exercises = sqlx::query_as::<_, Exercise>(
        "SELECT id, name, notes FROM exercises ORDER BY name COLLATE NOCASE",
    )
    .fetch_all(&state.pool)
    .await?;
    Ok(Json(exercises))
}

pub async fn create_exercise(
    State(state): State<AppState>,
    Json(body): Json<CreateExercise>,
) -> AppResult<(StatusCode, Json<Exercise>)> {
    let exercise = sqlx::query_as::<_, Exercise>(
        "INSERT INTO exercises (name, notes) VALUES (?, ?) RETURNING id, name, notes",
    )
    .bind(&body.name)
    .bind(&body.notes)
    .fetch_one(&state.pool)
    .await?;
    Ok((StatusCode::CREATED, Json(exercise)))
}
