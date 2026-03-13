use axum::{
    extract::{Path, State},
    http::StatusCode,
    Json,
};
use serde::{Deserialize, Serialize};

use crate::{error::AppResult, models::AppState};

#[derive(Serialize, sqlx::FromRow)]
pub struct WorkoutSummary {
    pub id: i64,
    pub started_at: String,
    pub finished_at: Option<String>,
    pub notes: Option<String>,
    pub set_count: i64,
}

#[derive(Serialize)]
pub struct WorkoutDetail {
    pub id: i64,
    pub started_at: String,
    pub finished_at: Option<String>,
    pub notes: Option<String>,
    pub sets: Vec<WorkoutSetRow>,
}

#[derive(Serialize, sqlx::FromRow)]
pub struct WorkoutSetRow {
    pub id: i64,
    pub exercise_id: i64,
    pub exercise_name: String,
    pub set_number: i64,
    pub reps: i64,
    pub weight_kg: f64,
}

#[derive(sqlx::FromRow)]
struct WorkoutRow {
    id: i64,
    started_at: String,
    finished_at: Option<String>,
    notes: Option<String>,
}

#[derive(Deserialize)]
pub struct AddSet {
    pub exercise_id: i64,
    pub set_number: i64,
    pub reps: i64,
    pub weight_kg: f64,
}

/// # Errors
/// Returns an error if the database query fails.
pub async fn list_workouts(State(state): State<AppState>) -> AppResult<Json<Vec<WorkoutSummary>>> {
    let workouts = sqlx::query_as::<_, WorkoutSummary>(
        r"SELECT w.id, w.started_at, w.finished_at, w.notes,
                  COUNT(s.id) as set_count
           FROM workouts w
           LEFT JOIN workout_sets s ON s.workout_id = w.id
           GROUP BY w.id
           ORDER BY w.started_at DESC",
    )
    .fetch_all(&state.pool)
    .await?;
    Ok(Json(workouts))
}

/// # Errors
/// Returns an error if the database insert fails.
pub async fn create_workout(
    State(state): State<AppState>,
) -> AppResult<(StatusCode, Json<WorkoutSummary>)> {
    let workout = sqlx::query_as::<_, WorkoutSummary>(
        "INSERT INTO workouts DEFAULT VALUES \
         RETURNING id, started_at, finished_at, notes, 0 as set_count",
    )
    .fetch_one(&state.pool)
    .await?;
    Ok((StatusCode::CREATED, Json(workout)))
}

/// # Errors
/// Returns `NOT_FOUND` if the workout doesn't exist, or an error if the query fails.
pub async fn get_workout(
    State(state): State<AppState>,
    Path(id): Path<i64>,
) -> AppResult<Json<WorkoutDetail>> {
    let row = sqlx::query_as::<_, WorkoutRow>(
        "SELECT id, started_at, finished_at, notes FROM workouts WHERE id = ?",
    )
    .bind(id)
    .fetch_optional(&state.pool)
    .await?
    .ok_or(StatusCode::NOT_FOUND)?;

    let sets = sqlx::query_as::<_, WorkoutSetRow>(
        r"SELECT s.id, s.exercise_id, e.name as exercise_name,
                  s.set_number, s.reps, s.weight_kg
           FROM workout_sets s
           JOIN exercises e ON e.id = s.exercise_id
           WHERE s.workout_id = ?
           ORDER BY s.id",
    )
    .bind(id)
    .fetch_all(&state.pool)
    .await?;

    Ok(Json(WorkoutDetail {
        id: row.id,
        started_at: row.started_at,
        finished_at: row.finished_at,
        notes: row.notes,
        sets,
    }))
}

/// # Errors
/// Returns `NOT_FOUND` if the workout doesn't exist or is already finished.
pub async fn finish_workout(
    State(state): State<AppState>,
    Path(id): Path<i64>,
) -> AppResult<StatusCode> {
    let result = sqlx::query(
        "UPDATE workouts SET finished_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now') \
         WHERE id = ? AND finished_at IS NULL",
    )
    .bind(id)
    .execute(&state.pool)
    .await?;
    if result.rows_affected() == 0 {
        return Err(StatusCode::NOT_FOUND.into());
    }
    Ok(StatusCode::NO_CONTENT)
}

/// # Errors
/// Returns an error if the database insert fails (e.g. invalid workout or exercise id).
pub async fn add_set(
    State(state): State<AppState>,
    Path(workout_id): Path<i64>,
    Json(body): Json<AddSet>,
) -> AppResult<(StatusCode, Json<WorkoutSetRow>)> {
    let set = sqlx::query_as::<_, WorkoutSetRow>(
        r"INSERT INTO workout_sets (workout_id, exercise_id, set_number, reps, weight_kg)
           VALUES (?, ?, ?, ?, ?)
           RETURNING id, exercise_id,
               (SELECT name FROM exercises WHERE id = exercise_id) as exercise_name,
               set_number, reps, weight_kg",
    )
    .bind(workout_id)
    .bind(body.exercise_id)
    .bind(body.set_number)
    .bind(body.reps)
    .bind(body.weight_kg)
    .fetch_one(&state.pool)
    .await?;
    Ok((StatusCode::CREATED, Json(set)))
}

/// # Errors
/// Returns `NOT_FOUND` if the workout doesn't exist.
pub async fn delete_workout(
    State(state): State<AppState>,
    Path(id): Path<i64>,
) -> AppResult<StatusCode> {
    let result = sqlx::query("DELETE FROM workouts WHERE id = ?")
        .bind(id)
        .execute(&state.pool)
        .await?;
    if result.rows_affected() == 0 {
        return Err(StatusCode::NOT_FOUND.into());
    }
    Ok(StatusCode::NO_CONTENT)
}

/// # Errors
/// Returns `NOT_FOUND` if the workout doesn't exist or is still active.
pub async fn restart_workout(
    State(state): State<AppState>,
    Path(id): Path<i64>,
) -> AppResult<StatusCode> {
    let result = sqlx::query(
        "UPDATE workouts SET finished_at = NULL WHERE id = ? AND finished_at IS NOT NULL",
    )
    .bind(id)
    .execute(&state.pool)
    .await?;
    if result.rows_affected() == 0 {
        return Err(StatusCode::NOT_FOUND.into());
    }
    Ok(StatusCode::NO_CONTENT)
}

/// # Errors
/// Returns `NOT_FOUND` if the set doesn't exist in that workout.
pub async fn delete_set(
    State(state): State<AppState>,
    Path((workout_id, set_id)): Path<(i64, i64)>,
) -> AppResult<StatusCode> {
    let result = sqlx::query("DELETE FROM workout_sets WHERE id = ? AND workout_id = ?")
        .bind(set_id)
        .bind(workout_id)
        .execute(&state.pool)
        .await?;
    if result.rows_affected() == 0 {
        return Err(StatusCode::NOT_FOUND.into());
    }
    Ok(StatusCode::NO_CONTENT)
}
