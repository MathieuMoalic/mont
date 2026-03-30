use axum::{
    extract::{Path, Query, State},
    http::StatusCode,
    Json,
};
use serde::{Deserialize, Serialize};

use crate::{error::AppResult, models::AppState, pagination::Pagination};

#[derive(Serialize, sqlx::FromRow)]
pub struct Exercise {
    pub id: i64,
    pub name: String,
    pub notes: Option<String>,
    pub muscle_group: Option<String>,
    pub equipment: Option<String>,
}

#[derive(Serialize, sqlx::FromRow)]
pub struct PersonalRecord {
    pub max_weight_kg: f64,
    pub max_weight_date: String,
    pub max_weight_reps: i64,
    pub max_reps: i64,
    pub max_reps_date: String,
    pub max_reps_weight_kg: f64,
    pub max_volume_workout: f64,
    pub max_volume_date: String,
    pub best_set_score: f64,  // weight * reps
    pub best_set_date: String,
    pub best_set_weight_kg: f64,
    pub best_set_reps: i64,
}

#[derive(Deserialize)]
pub struct CreateExercise {
    pub name: String,
    pub notes: Option<String>,
    pub muscle_group: Option<String>,
    pub equipment: Option<String>,
}

#[derive(Deserialize)]
pub struct UpdateExercise {
    pub name: Option<String>,
    pub notes: Option<String>,
    pub muscle_group: Option<String>,
    pub equipment: Option<String>,
}

/// # Errors
/// Returns an error if the database query fails.
pub async fn list_exercises(
    State(state): State<AppState>,
    Query(pagination): Query<Pagination>,
) -> AppResult<Json<Vec<Exercise>>> {
    let exercises = sqlx::query_as::<_, Exercise>(
        r"SELECT e.id, e.name, e.notes, e.muscle_group, e.equipment
          FROM exercises e
          LEFT JOIN workout_sets s ON s.exercise_id = e.id
          LEFT JOIN workouts w ON w.id = s.workout_id
          GROUP BY e.id
          ORDER BY MAX(s.id) DESC NULLS LAST, e.id DESC
          LIMIT ? OFFSET ?",
    )
    .bind(pagination.limit)
    .bind(pagination.offset)
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
        "INSERT INTO exercises (name, notes, muscle_group, equipment) VALUES (?, ?, ?, ?) RETURNING id, name, notes, muscle_group, equipment",
    )
    .bind(&body.name)
    .bind(&body.notes)
    .bind(&body.muscle_group)
    .bind(&body.equipment)
    .fetch_one(&state.pool)
    .await
    .map_err(|e| -> crate::error::AppError {
        if matches!(e, sqlx::Error::Database(ref db_err) if db_err.is_unique_violation()) {
            (StatusCode::CONFLICT, format!("Exercise '{}' already exists", body.name)).into()
        } else {
            e.into()
        }
    })?;
    Ok((StatusCode::CREATED, Json(exercise)))
}

/// # Errors
/// Returns `NOT_FOUND` if the exercise doesn't exist, or an error if the query fails
/// or the name conflicts with an existing exercise.
pub async fn update_exercise(
    State(state): State<AppState>,
    Path(id): Path<i64>,
    Json(body): Json<UpdateExercise>,
) -> AppResult<Json<Exercise>> {
    // Verify exercise exists
    let exists: bool = sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM exercises WHERE id = ?)")
        .bind(id)
        .fetch_one(&state.pool)
        .await?;
    if !exists {
        return Err(StatusCode::NOT_FOUND.into());
    }

    // Build dynamic UPDATE query based on provided fields
    let mut updates = Vec::new();

    if body.name.is_some() {
        updates.push("name = ?");
    }
    if body.notes.is_some() || body.notes == Some(String::new()) {
        updates.push("notes = ?");
    }
    if body.muscle_group.is_some() || body.muscle_group == Some(String::new()) {
        updates.push("muscle_group = ?");
    }
    if body.equipment.is_some() || body.equipment == Some(String::new()) {
        updates.push("equipment = ?");
    }

    if updates.is_empty() {
        // No fields to update, just return existing exercise
        let exercise = sqlx::query_as::<_, Exercise>(
            "SELECT id, name, notes, muscle_group, equipment FROM exercises WHERE id = ?",
        )
        .bind(id)
        .fetch_one(&state.pool)
        .await?;
        return Ok(Json(exercise));
    }

    let mut query = String::from("UPDATE exercises SET ");
    query.push_str(&updates.join(", "));
    query.push_str(" WHERE id = ? RETURNING id, name, notes, muscle_group, equipment");

    let mut q = sqlx::query_as::<_, Exercise>(&query);
    if let Some(ref name) = body.name {
        q = q.bind(name);
    }
    if body.notes.is_some() {
        q = q.bind(&body.notes);
    }
    if body.muscle_group.is_some() {
        q = q.bind(&body.muscle_group);
    }
    if body.equipment.is_some() {
        q = q.bind(&body.equipment);
    }
    q = q.bind(id);

    let exercise = q.fetch_one(&state.pool).await.map_err(|e| -> crate::error::AppError {
        if matches!(e, sqlx::Error::Database(ref db_err) if db_err.is_unique_violation()) {
            (
                StatusCode::CONFLICT,
                format!("Exercise '{}' already exists", body.name.as_ref().unwrap_or(&String::new())),
            )
                .into()
        } else {
            e.into()
        }
    })?;

    Ok(Json(exercise))
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
    Query(pagination): Query<Pagination>,
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
          ORDER BY w.started_at ASC
          LIMIT ? OFFSET ?",
    )
    .bind(id)
    .bind(id)
    .bind(pagination.limit)
    .bind(pagination.offset)
    .fetch_all(&state.pool)
    .await?;

    Ok(Json(points))
}

/// # Errors
/// Returns `NOT_FOUND` if the exercise doesn't exist, or an error if the query fails.
pub async fn exercise_personal_records(
    State(state): State<AppState>,
    Path(id): Path<i64>,
) -> AppResult<Json<PersonalRecord>> {
    // Verify exercise exists
    let exists: bool = sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM exercises WHERE id = ?)")
        .bind(id)
        .fetch_one(&state.pool)
        .await?;
    if !exists {
        return Err(StatusCode::NOT_FOUND.into());
    }

    // Query for all PR records in one go
    let pr = sqlx::query_as::<_, PersonalRecord>(
        r"WITH exercise_sets AS (
              SELECT s.weight_kg, s.reps, w.started_at, 
                     (s.weight_kg * CAST(s.reps AS REAL)) as set_score
              FROM workout_sets s
              JOIN workouts w ON w.id = s.workout_id
              WHERE s.exercise_id = ?
          ),
          workout_volumes AS (
              SELECT w.started_at, SUM(s.weight_kg * CAST(s.reps AS REAL)) as volume
              FROM workout_sets s
              JOIN workouts w ON w.id = s.workout_id
              WHERE s.exercise_id = ?
              GROUP BY w.id
          ),
          max_weight AS (
              SELECT weight_kg, started_at, reps
              FROM exercise_sets
              ORDER BY weight_kg DESC, reps DESC
              LIMIT 1
          ),
          max_reps AS (
              SELECT reps, started_at, weight_kg
              FROM exercise_sets
              ORDER BY reps DESC, weight_kg DESC
              LIMIT 1
          ),
          max_volume AS (
              SELECT volume, started_at
              FROM workout_volumes
              ORDER BY volume DESC
              LIMIT 1
          ),
          best_set AS (
              SELECT set_score, started_at, weight_kg, reps
              FROM exercise_sets
              ORDER BY set_score DESC
              LIMIT 1
          )
          SELECT
              (SELECT weight_kg FROM max_weight) as max_weight_kg,
              (SELECT started_at FROM max_weight) as max_weight_date,
              (SELECT reps FROM max_weight) as max_weight_reps,
              (SELECT reps FROM max_reps) as max_reps,
              (SELECT started_at FROM max_reps) as max_reps_date,
              (SELECT weight_kg FROM max_reps) as max_reps_weight_kg,
              (SELECT volume FROM max_volume) as max_volume_workout,
              (SELECT started_at FROM max_volume) as max_volume_date,
              (SELECT set_score FROM best_set) as best_set_score,
              (SELECT started_at FROM best_set) as best_set_date,
              (SELECT weight_kg FROM best_set) as best_set_weight_kg,
              (SELECT reps FROM best_set) as best_set_reps",
    )
    .bind(id)
    .bind(id)
    .fetch_one(&state.pool)
    .await?;

    Ok(Json(pr))
}
