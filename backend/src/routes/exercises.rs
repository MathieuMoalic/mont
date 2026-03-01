use axum::{
    extract::{Path, State},
    http::StatusCode,
    Json,
};
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

/// # Errors
/// Returns an error if the database query fails.
pub async fn list_exercises(State(state): State<AppState>) -> AppResult<Json<Vec<Exercise>>> {
    let exercises = sqlx::query_as::<_, Exercise>(
        "SELECT id, name, notes FROM exercises ORDER BY name COLLATE NOCASE",
    )
    .fetch_all(&state.pool)
    .await?;
    Ok(Json(exercises))
}

/// # Errors
/// Returns an error if the database query fails or the name is a duplicate.
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

#[derive(Serialize, sqlx::FromRow)]
pub struct ExerciseHistoryPoint {
    pub workout_date: String,
    pub max_weight_kg: f64,
    pub reps_at_max: i64,
    pub total_sets: i64,
    pub total_reps: i64,
    pub total_volume: f64,
}

/// # Errors
/// Returns `NOT_FOUND` if the exercise doesn't exist, or an error if the query fails.
pub async fn exercise_history(
    State(state): State<AppState>,
    Path(id): Path<i64>,
) -> AppResult<Json<Vec<ExerciseHistoryPoint>>> {
    // Verify exercise exists
    let exists: bool = sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM exercises WHERE id = ?)")
        .bind(id)
        .fetch_one(&state.pool)
        .await?;
    if !exists {
        return Err(StatusCode::NOT_FOUND.into());
    }

    let points = sqlx::query_as::<_, ExerciseHistoryPoint>(
        r"SELECT
              w.started_at                    AS workout_date,
              MAX(s.weight_kg)                AS max_weight_kg,
              (SELECT s2.reps
               FROM workout_sets s2
               WHERE s2.workout_id = w.id AND s2.exercise_id = ?
               ORDER BY s2.weight_kg DESC, s2.reps DESC
               LIMIT 1)                       AS reps_at_max,
              COUNT(*)                        AS total_sets,
              SUM(s.reps)                     AS total_reps,
              SUM(CAST(s.reps AS REAL) * s.weight_kg) AS total_volume
          FROM workout_sets s
          JOIN workouts w ON w.id = s.workout_id
          WHERE s.exercise_id = ?
          GROUP BY w.id
          ORDER BY w.started_at ASC",
    )
    .bind(id)
    .bind(id)
    .fetch_all(&state.pool)
    .await?;

    Ok(Json(points))
}
