use axum::{
    Json,
    extract::{Path, Query, State},
    http::StatusCode,
};
use serde::{Deserialize, Serialize};

use crate::{error::AppResult, models::AppState};

#[derive(Serialize, sqlx::FromRow)]
pub struct CalorieEntry {
    pub id: i64,
    pub day: String,
    pub meal_period: String,
    pub name: String,
    pub protein_per_100g: f64,
    pub carbs_per_100g: f64,
    pub fats_per_100g: f64,
    pub weight_g: f64,
    pub protein_g: f64,
    pub carbs_g: f64,
    pub fats_g: f64,
    pub kcal: i64,
}

#[derive(Serialize, sqlx::FromRow)]
pub struct CalorieExerciseEntry {
    pub id: i64,
    pub day: String,
    pub name: String,
    pub kcal: i64,
}

#[derive(Serialize, sqlx::FromRow)]
pub struct NutritionTargets {
    pub protein_g: f64,
    pub carbs_g: f64,
    pub fats_g: f64,
}

#[derive(Serialize, sqlx::FromRow)]
pub struct SavedFood {
    pub id: i64,
    pub name: String,
    pub protein_per_100g: f64,
    pub carbs_per_100g: f64,
    pub fats_per_100g: f64,
    pub last_weight_g: f64,
}

#[derive(Deserialize)]
pub struct ListCaloriesQuery {
    pub start: String,
    pub end: String,
}

#[derive(Deserialize)]
pub struct FoodSearchQuery {
    pub q: Option<String>,
}

#[derive(Deserialize)]
pub struct CreateCalorieEntry {
    pub day: String,
    pub meal_period: String,
    pub name: String,
    pub protein_per_100g: f64,
    pub carbs_per_100g: f64,
    pub fats_per_100g: f64,
    pub weight_g: f64,
}

#[derive(Deserialize)]
pub struct UpdateCalorieEntry {
    pub day: Option<String>,
    pub meal_period: Option<String>,
    pub name: Option<String>,
    pub protein_per_100g: Option<f64>,
    pub carbs_per_100g: Option<f64>,
    pub fats_per_100g: Option<f64>,
    pub weight_g: Option<f64>,
}

#[derive(Deserialize)]
pub struct CreateCalorieExerciseEntry {
    pub day: String,
    pub name: String,
    pub kcal: i64,
}

#[derive(Deserialize)]
pub struct UpdateCalorieExerciseEntry {
    pub day: Option<String>,
    pub name: Option<String>,
    pub kcal: Option<i64>,
}

#[derive(Deserialize)]
pub struct UpdateNutritionTargets {
    pub protein_g: f64,
    pub carbs_g: f64,
    pub fats_g: f64,
}

fn calculate_from_per_100g(
    protein_per_100g: f64,
    carbs_per_100g: f64,
    fats_per_100g: f64,
    weight_g: f64,
) -> (f64, f64, f64, i64) {
    let factor = weight_g / 100.0;
    let protein_g = protein_per_100g * factor;
    let carbs_g = carbs_per_100g * factor;
    let fats_g = fats_per_100g * factor;
    #[allow(clippy::cast_possible_truncation)]
    let kcal = (protein_g * 4.0 + carbs_g * 4.0 + fats_g * 9.0).round() as i64;
    (protein_g, carbs_g, fats_g, kcal)
}

fn validate_meal_period(meal_period: &str) -> bool {
    matches!(meal_period, "morning" | "afternoon" | "evening")
}

fn validate_day(day: &str) -> bool {
    if day.len() != 10 {
        return false;
    }
    let bytes = day.as_bytes();
    bytes[4] == b'-'
        && bytes[7] == b'-'
        && bytes
            .iter()
            .enumerate()
            .all(|(i, b)| (i == 4 || i == 7) || b.is_ascii_digit())
}

async fn upsert_saved_food(
    pool: &sqlx::SqlitePool,
    name: &str,
    protein_per_100g: f64,
    carbs_per_100g: f64,
    fats_per_100g: f64,
    last_weight_g: f64,
) -> AppResult<()> {
    sqlx::query(
        "INSERT INTO saved_foods (name, protein_per_100g, carbs_per_100g, fats_per_100g, last_weight_g)
         VALUES (?, ?, ?, ?, ?)
         ON CONFLICT(name) DO UPDATE SET
            protein_per_100g = excluded.protein_per_100g,
            carbs_per_100g = excluded.carbs_per_100g,
            fats_per_100g = excluded.fats_per_100g,
            last_weight_g = excluded.last_weight_g",
    )
    .bind(name)
    .bind(protein_per_100g)
    .bind(carbs_per_100g)
    .bind(fats_per_100g)
    .bind(last_weight_g)
    .execute(pool)
    .await?;
    Ok(())
}

/// # Errors
/// Returns an error if the database query fails or query parameters are invalid.
pub async fn list_calories(
    State(state): State<AppState>,
    Query(query): Query<ListCaloriesQuery>,
) -> AppResult<Json<Vec<CalorieEntry>>> {
    if !validate_day(&query.start) || !validate_day(&query.end) {
        return Err((
            StatusCode::BAD_REQUEST,
            "start and end must be YYYY-MM-DD".to_string(),
        )
            .into());
    }

    let entries = sqlx::query_as::<_, CalorieEntry>(
        "SELECT id, day, meal_period, name,
                protein_per_100g, carbs_per_100g, fats_per_100g, weight_g,
                protein_g, carbs_g, fats_g, kcal
         FROM calorie_entries
         WHERE day BETWEEN ? AND ?
         ORDER BY day ASC,
           CASE meal_period
             WHEN 'morning' THEN 0
             WHEN 'afternoon' THEN 1
             ELSE 2
           END,
           id ASC",
    )
    .bind(query.start)
    .bind(query.end)
    .fetch_all(&state.pool)
    .await?;
    Ok(Json(entries))
}

/// # Errors
/// Returns an error if the database query fails.
pub async fn list_saved_foods(
    State(state): State<AppState>,
    Query(query): Query<FoodSearchQuery>,
) -> AppResult<Json<Vec<SavedFood>>> {
    let foods = if let Some(q) = query.q.as_deref() {
        sqlx::query_as::<_, SavedFood>(
            "SELECT id, name, protein_per_100g, carbs_per_100g, fats_per_100g, last_weight_g
             FROM saved_foods
             WHERE name LIKE '%' || ? || '%'
             ORDER BY name ASC
             LIMIT 100",
        )
        .bind(q.trim())
        .fetch_all(&state.pool)
        .await?
    } else {
        sqlx::query_as::<_, SavedFood>(
            "SELECT id, name, protein_per_100g, carbs_per_100g, fats_per_100g, last_weight_g
             FROM saved_foods
             ORDER BY name ASC
             LIMIT 100",
        )
        .fetch_all(&state.pool)
        .await?
    };
    Ok(Json(foods))
}

/// # Errors
/// Returns an error if validation fails or the insert fails.
pub async fn create_calorie_entry(
    State(state): State<AppState>,
    Json(body): Json<CreateCalorieEntry>,
) -> AppResult<(StatusCode, Json<CalorieEntry>)> {
    if !validate_day(&body.day) {
        return Err((
            StatusCode::BAD_REQUEST,
            "day must be YYYY-MM-DD".to_string(),
        )
            .into());
    }
    if !validate_meal_period(&body.meal_period) {
        return Err((
            StatusCode::BAD_REQUEST,
            "meal_period must be morning, afternoon, or evening".to_string(),
        )
            .into());
    }
    if body.name.trim().is_empty() {
        return Err((
            StatusCode::BAD_REQUEST,
            "Entry name cannot be empty".to_string(),
        )
            .into());
    }
    if body.protein_per_100g < 0.0
        || body.carbs_per_100g < 0.0
        || body.fats_per_100g < 0.0
        || body.weight_g <= 0.0
    {
        return Err((
            StatusCode::BAD_REQUEST,
            "Per-100g macros must be non-negative and weight must be > 0".to_string(),
        )
            .into());
    }

    let (protein_g, carbs_g, fats_g, kcal) = calculate_from_per_100g(
        body.protein_per_100g,
        body.carbs_per_100g,
        body.fats_per_100g,
        body.weight_g,
    );

    let entry = sqlx::query_as::<_, CalorieEntry>(
        "INSERT INTO calorie_entries (
            day, meal_period, name,
            protein_per_100g, carbs_per_100g, fats_per_100g, weight_g,
            protein_g, carbs_g, fats_g, kcal
         ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
         RETURNING id, day, meal_period, name,
                   protein_per_100g, carbs_per_100g, fats_per_100g, weight_g,
                   protein_g, carbs_g, fats_g, kcal",
    )
    .bind(body.day)
    .bind(body.meal_period)
    .bind(body.name.trim())
    .bind(body.protein_per_100g)
    .bind(body.carbs_per_100g)
    .bind(body.fats_per_100g)
    .bind(body.weight_g)
    .bind(protein_g)
    .bind(carbs_g)
    .bind(fats_g)
    .bind(kcal)
    .fetch_one(&state.pool)
    .await?;
    upsert_saved_food(
        &state.pool,
        entry.name.as_str(),
        entry.protein_per_100g,
        entry.carbs_per_100g,
        entry.fats_per_100g,
        entry.weight_g,
    )
    .await?;

    Ok((StatusCode::CREATED, Json(entry)))
}

/// # Errors
/// Returns `NOT_FOUND` if the entry doesn't exist or validation fails.
pub async fn update_calorie_entry(
    State(state): State<AppState>,
    Path(id): Path<i64>,
    Json(body): Json<UpdateCalorieEntry>,
) -> AppResult<Json<CalorieEntry>> {
    if let Some(day) = &body.day
        && !validate_day(day)
    {
        return Err((
            StatusCode::BAD_REQUEST,
            "day must be YYYY-MM-DD".to_string(),
        )
            .into());
    }
    if let Some(meal_period) = &body.meal_period
        && !validate_meal_period(meal_period)
    {
        return Err((
            StatusCode::BAD_REQUEST,
            "meal_period must be morning, afternoon, or evening".to_string(),
        )
            .into());
    }
    if let Some(name) = &body.name
        && name.trim().is_empty()
    {
        return Err((
            StatusCode::BAD_REQUEST,
            "Entry name cannot be empty".to_string(),
        )
            .into());
    }
    if body.protein_per_100g.is_some_and(|v| v < 0.0)
        || body.carbs_per_100g.is_some_and(|v| v < 0.0)
        || body.fats_per_100g.is_some_and(|v| v < 0.0)
        || body.weight_g.is_some_and(|v| v <= 0.0)
    {
        return Err((
            StatusCode::BAD_REQUEST,
            "Per-100g macros must be non-negative and weight must be > 0".to_string(),
        )
            .into());
    }

    let current = sqlx::query_as::<_, CalorieEntry>(
        "SELECT id, day, meal_period, name,
                protein_per_100g, carbs_per_100g, fats_per_100g, weight_g,
                protein_g, carbs_g, fats_g, kcal
         FROM calorie_entries WHERE id = ?",
    )
    .bind(id)
    .fetch_optional(&state.pool)
    .await?
    .ok_or(StatusCode::NOT_FOUND)?;

    let protein_per_100g = body.protein_per_100g.unwrap_or(current.protein_per_100g);
    let carbs_per_100g = body.carbs_per_100g.unwrap_or(current.carbs_per_100g);
    let fats_per_100g = body.fats_per_100g.unwrap_or(current.fats_per_100g);
    let weight_g = body.weight_g.unwrap_or(current.weight_g);
    let (protein_g, carbs_g, fats_g, kcal) =
        calculate_from_per_100g(protein_per_100g, carbs_per_100g, fats_per_100g, weight_g);

    let entry = sqlx::query_as::<_, CalorieEntry>(
        "UPDATE calorie_entries
         SET day = COALESCE(?, day),
             meal_period = COALESCE(?, meal_period),
             name = COALESCE(?, name),
             protein_per_100g = ?,
             carbs_per_100g = ?,
             fats_per_100g = ?,
             weight_g = ?,
             protein_g = ?,
             carbs_g = ?,
             fats_g = ?,
             kcal = ?
         WHERE id = ?
         RETURNING id, day, meal_period, name,
                   protein_per_100g, carbs_per_100g, fats_per_100g, weight_g,
                   protein_g, carbs_g, fats_g, kcal",
    )
    .bind(body.day)
    .bind(body.meal_period)
    .bind(body.name.as_deref().map(str::trim))
    .bind(protein_per_100g)
    .bind(carbs_per_100g)
    .bind(fats_per_100g)
    .bind(weight_g)
    .bind(protein_g)
    .bind(carbs_g)
    .bind(fats_g)
    .bind(kcal)
    .bind(id)
    .fetch_optional(&state.pool)
    .await?
    .ok_or(StatusCode::NOT_FOUND)?;
    upsert_saved_food(
        &state.pool,
        entry.name.as_str(),
        entry.protein_per_100g,
        entry.carbs_per_100g,
        entry.fats_per_100g,
        entry.weight_g,
    )
    .await?;

    Ok(Json(entry))
}

/// # Errors
/// Returns `NOT_FOUND` if the entry doesn't exist.
pub async fn delete_calorie_entry(
    State(state): State<AppState>,
    Path(id): Path<i64>,
) -> AppResult<StatusCode> {
    let result = sqlx::query("DELETE FROM calorie_entries WHERE id = ?")
        .bind(id)
        .execute(&state.pool)
        .await?;
    if result.rows_affected() == 0 {
        return Err(StatusCode::NOT_FOUND.into());
    }
    Ok(StatusCode::NO_CONTENT)
}

/// # Errors
/// Returns an error if the database query fails or query parameters are invalid.
pub async fn list_calorie_exercises(
    State(state): State<AppState>,
    Query(query): Query<ListCaloriesQuery>,
) -> AppResult<Json<Vec<CalorieExerciseEntry>>> {
    if !validate_day(&query.start) || !validate_day(&query.end) {
        return Err((
            StatusCode::BAD_REQUEST,
            "start and end must be YYYY-MM-DD".to_string(),
        )
            .into());
    }
    let entries = sqlx::query_as::<_, CalorieExerciseEntry>(
        "SELECT id, day, name, kcal
         FROM calorie_exercises
         WHERE day BETWEEN ? AND ?
         ORDER BY day ASC, id ASC",
    )
    .bind(query.start)
    .bind(query.end)
    .fetch_all(&state.pool)
    .await?;
    Ok(Json(entries))
}

/// # Errors
/// Returns an error if validation fails or insert fails.
pub async fn create_calorie_exercise(
    State(state): State<AppState>,
    Json(body): Json<CreateCalorieExerciseEntry>,
) -> AppResult<(StatusCode, Json<CalorieExerciseEntry>)> {
    if !validate_day(&body.day) {
        return Err((
            StatusCode::BAD_REQUEST,
            "day must be YYYY-MM-DD".to_string(),
        )
            .into());
    }
    if body.name.trim().is_empty() {
        return Err((
            StatusCode::BAD_REQUEST,
            "Exercise name cannot be empty".to_string(),
        )
            .into());
    }
    if body.kcal < 0 {
        return Err((
            StatusCode::BAD_REQUEST,
            "kcal must be non-negative".to_string(),
        )
            .into());
    }
    let entry = sqlx::query_as::<_, CalorieExerciseEntry>(
        "INSERT INTO calorie_exercises (day, name, kcal)
         VALUES (?, ?, ?)
         RETURNING id, day, name, kcal",
    )
    .bind(body.day)
    .bind(body.name.trim())
    .bind(body.kcal)
    .fetch_one(&state.pool)
    .await?;
    Ok((StatusCode::CREATED, Json(entry)))
}

/// # Errors
/// Returns `NOT_FOUND` if the entry doesn't exist or validation fails.
pub async fn update_calorie_exercise(
    State(state): State<AppState>,
    Path(id): Path<i64>,
    Json(body): Json<UpdateCalorieExerciseEntry>,
) -> AppResult<Json<CalorieExerciseEntry>> {
    if let Some(day) = &body.day
        && !validate_day(day)
    {
        return Err((
            StatusCode::BAD_REQUEST,
            "day must be YYYY-MM-DD".to_string(),
        )
            .into());
    }
    if let Some(name) = &body.name
        && name.trim().is_empty()
    {
        return Err((
            StatusCode::BAD_REQUEST,
            "Exercise name cannot be empty".to_string(),
        )
            .into());
    }
    if body.kcal.is_some_and(|v| v < 0) {
        return Err((
            StatusCode::BAD_REQUEST,
            "kcal must be non-negative".to_string(),
        )
            .into());
    }

    let entry = sqlx::query_as::<_, CalorieExerciseEntry>(
        "UPDATE calorie_exercises
         SET day = COALESCE(?, day),
             name = COALESCE(?, name),
             kcal = COALESCE(?, kcal)
         WHERE id = ?
         RETURNING id, day, name, kcal",
    )
    .bind(body.day)
    .bind(body.name.as_deref().map(str::trim))
    .bind(body.kcal)
    .bind(id)
    .fetch_optional(&state.pool)
    .await?
    .ok_or(StatusCode::NOT_FOUND)?;
    Ok(Json(entry))
}

/// # Errors
/// Returns `NOT_FOUND` if the entry doesn't exist.
pub async fn delete_calorie_exercise(
    State(state): State<AppState>,
    Path(id): Path<i64>,
) -> AppResult<StatusCode> {
    let result = sqlx::query("DELETE FROM calorie_exercises WHERE id = ?")
        .bind(id)
        .execute(&state.pool)
        .await?;
    if result.rows_affected() == 0 {
        return Err(StatusCode::NOT_FOUND.into());
    }
    Ok(StatusCode::NO_CONTENT)
}

/// # Errors
/// Returns an error if DB query fails.
pub async fn get_nutrition_targets(
    State(state): State<AppState>,
) -> AppResult<Json<NutritionTargets>> {
    let targets = sqlx::query_as::<_, NutritionTargets>(
        "SELECT protein_g, carbs_g, fats_g FROM nutrition_targets WHERE id = 1",
    )
    .fetch_optional(&state.pool)
    .await?;
    Ok(Json(targets.unwrap_or(NutritionTargets {
        protein_g: 0.0,
        carbs_g: 0.0,
        fats_g: 0.0,
    })))
}

/// # Errors
/// Returns an error if validation or DB write fails.
pub async fn update_nutrition_targets(
    State(state): State<AppState>,
    Json(body): Json<UpdateNutritionTargets>,
) -> AppResult<StatusCode> {
    if body.protein_g < 0.0 || body.carbs_g < 0.0 || body.fats_g < 0.0 {
        return Err((
            StatusCode::BAD_REQUEST,
            "Targets must be non-negative".to_string(),
        )
            .into());
    }
    sqlx::query(
        "INSERT INTO nutrition_targets (id, protein_g, carbs_g, fats_g)
         VALUES (1, ?, ?, ?)
         ON CONFLICT(id) DO UPDATE SET
           protein_g = excluded.protein_g,
           carbs_g = excluded.carbs_g,
           fats_g = excluded.fats_g",
    )
    .bind(body.protein_g)
    .bind(body.carbs_g)
    .bind(body.fats_g)
    .execute(&state.pool)
    .await?;
    Ok(StatusCode::NO_CONTENT)
}
