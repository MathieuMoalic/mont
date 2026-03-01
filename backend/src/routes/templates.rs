use axum::{
    extract::{Path, State},
    http::StatusCode,
    Json,
};
use serde::{Deserialize, Serialize};

use crate::{error::AppResult, models::AppState};

// ── Models ────────────────────────────────────────────────────────────────────

#[derive(Serialize, sqlx::FromRow)]
pub struct TemplateSummary {
    pub id: i64,
    pub name: String,
    pub notes: Option<String>,
    pub set_count: i64,
}

#[derive(Serialize)]
pub struct TemplateDetail {
    pub id: i64,
    pub name: String,
    pub notes: Option<String>,
    pub sets: Vec<TemplateSetRow>,
}

#[derive(Serialize, sqlx::FromRow)]
pub struct TemplateSetRow {
    pub id: i64,
    pub exercise_id: i64,
    pub exercise_name: String,
    pub set_number: i64,
    pub target_reps: i64,
    pub target_weight_kg: f64,
}

#[derive(sqlx::FromRow)]
struct TemplateRow {
    id: i64,
    name: String,
    notes: Option<String>,
}

#[derive(Deserialize)]
pub struct CreateTemplate {
    pub name: String,
    pub notes: Option<String>,
    pub sets: Vec<CreateTemplateSet>,
}

#[derive(Deserialize)]
pub struct CreateTemplateSet {
    pub exercise_id: i64,
    pub set_number: i64,
    pub target_reps: i64,
    pub target_weight_kg: f64,
}

// ── Handlers ──────────────────────────────────────────────────────────────────

/// # Errors
/// Returns an error if the database query fails.
pub async fn list_templates(
    State(state): State<AppState>,
) -> AppResult<Json<Vec<TemplateSummary>>> {
    let templates = sqlx::query_as::<_, TemplateSummary>(
        r"SELECT t.id, t.name, t.notes, COUNT(s.id) AS set_count
          FROM workout_templates t
          LEFT JOIN template_sets s ON s.template_id = t.id
          GROUP BY t.id
          ORDER BY t.name COLLATE NOCASE",
    )
    .fetch_all(&state.pool)
    .await?;
    Ok(Json(templates))
}

/// # Errors
/// Returns `NOT_FOUND` if the template doesn't exist.
pub async fn get_template(
    State(state): State<AppState>,
    Path(id): Path<i64>,
) -> AppResult<Json<TemplateDetail>> {
    let row = sqlx::query_as::<_, TemplateRow>(
        "SELECT id, name, notes FROM workout_templates WHERE id = ?",
    )
    .bind(id)
    .fetch_optional(&state.pool)
    .await?
    .ok_or(StatusCode::NOT_FOUND)?;

    let sets = sqlx::query_as::<_, TemplateSetRow>(
        r"SELECT s.id, s.exercise_id, e.name AS exercise_name,
                 s.set_number, s.target_reps, s.target_weight_kg
          FROM template_sets s
          JOIN exercises e ON e.id = s.exercise_id
          WHERE s.template_id = ?
          ORDER BY s.exercise_id, s.set_number",
    )
    .bind(id)
    .fetch_all(&state.pool)
    .await?;

    Ok(Json(TemplateDetail {
        id: row.id,
        name: row.name,
        notes: row.notes,
        sets,
    }))
}

/// # Errors
/// Returns an error if the database insert fails.
pub async fn create_template(
    State(state): State<AppState>,
    Json(body): Json<CreateTemplate>,
) -> AppResult<(StatusCode, Json<TemplateSummary>)> {
    let template = sqlx::query_as::<_, TemplateRow>(
        "INSERT INTO workout_templates (name, notes) VALUES (?, ?) RETURNING id, name, notes",
    )
    .bind(&body.name)
    .bind(&body.notes)
    .fetch_one(&state.pool)
    .await?;

    for s in &body.sets {
        sqlx::query(
            "INSERT INTO template_sets (template_id, exercise_id, set_number, target_reps, target_weight_kg) \
             VALUES (?, ?, ?, ?, ?)",
        )
        .bind(template.id)
        .bind(s.exercise_id)
        .bind(s.set_number)
        .bind(s.target_reps)
        .bind(s.target_weight_kg)
        .execute(&state.pool)
        .await?;
    }

    let count = i64::try_from(body.sets.len()).unwrap_or(0);
    Ok((
        StatusCode::CREATED,
        Json(TemplateSummary {
            id: template.id,
            name: template.name,
            notes: template.notes,
            set_count: count,
        }),
    ))
}

/// # Errors
/// Returns `NOT_FOUND` if the template doesn't exist.
pub async fn delete_template(
    State(state): State<AppState>,
    Path(id): Path<i64>,
) -> AppResult<StatusCode> {
    let result = sqlx::query("DELETE FROM workout_templates WHERE id = ?")
        .bind(id)
        .execute(&state.pool)
        .await?;
    if result.rows_affected() == 0 {
        return Err(StatusCode::NOT_FOUND.into());
    }
    Ok(StatusCode::NO_CONTENT)
}

/// Apply a template to an existing workout: add all template sets as actual sets.
///
/// # Errors
/// Returns `NOT_FOUND` if the workout or template doesn't exist.
pub async fn apply_template(
    State(state): State<AppState>,
    Path((workout_id, template_id)): Path<(i64, i64)>,
) -> AppResult<StatusCode> {
    // Verify workout exists
    let workout_exists: bool =
        sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM workouts WHERE id = ? AND finished_at IS NULL)")
            .bind(workout_id)
            .fetch_one(&state.pool)
            .await?;
    if !workout_exists {
        return Err(StatusCode::NOT_FOUND.into());
    }

    let sets = sqlx::query_as::<_, TemplateSetRow>(
        r"SELECT s.id, s.exercise_id, e.name AS exercise_name,
                 s.set_number, s.target_reps, s.target_weight_kg
          FROM template_sets s
          JOIN exercises e ON e.id = s.exercise_id
          WHERE s.template_id = ?
          ORDER BY s.exercise_id, s.set_number",
    )
    .bind(template_id)
    .fetch_all(&state.pool)
    .await?;

    if sets.is_empty() {
        return Err(StatusCode::NOT_FOUND.into());
    }

    for s in &sets {
        sqlx::query(
            "INSERT INTO workout_sets (workout_id, exercise_id, set_number, reps, weight_kg) \
             VALUES (?, ?, ?, ?, ?)",
        )
        .bind(workout_id)
        .bind(s.exercise_id)
        .bind(s.set_number)
        .bind(s.target_reps)
        .bind(s.target_weight_kg)
        .execute(&state.pool)
        .await?;
    }

    Ok(StatusCode::NO_CONTENT)
}
