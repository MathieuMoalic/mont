use axum::{
    Json,
    extract::{Path, Query, State},
    http::StatusCode,
};
use serde::{Deserialize, Serialize};

use crate::{error::AppResult, models::AppState, pagination::Pagination};

#[derive(Serialize, sqlx::FromRow)]
pub struct MealSummary {
    pub id: i64,
    pub name: String,
    pub total_grams: f64,
    pub protein_g: f64,
    pub carbs_g: f64,
    pub fats_g: f64,
    pub kcal: i64,
}

#[derive(Serialize)]
pub struct MealDetail {
    pub id: i64,
    pub name: String,
    pub ingredients: Vec<MealIngredientDetail>,
    pub totals: MealTotals,
}

#[derive(Serialize, sqlx::FromRow)]
pub struct MealIngredientDetail {
    pub id: i64,
    pub food_id: i64,
    pub food_name: String,
    pub food_brand: String,
    pub protein_per_100g: f64,
    pub carbs_per_100g: f64,
    pub fats_per_100g: f64,
    pub grams: f64,
    pub position: i64,
}

#[derive(Serialize)]
pub struct MealTotals {
    pub total_grams: f64,
    pub protein_g: f64,
    pub carbs_g: f64,
    pub fats_g: f64,
    pub kcal: i64,
}

#[derive(Deserialize)]
pub struct MealIngredientInput {
    pub food_id: i64,
    pub grams: f64,
}

#[derive(Deserialize)]
pub struct CreateMealBody {
    pub name: String,
    pub ingredients: Vec<MealIngredientInput>,
}

#[derive(Deserialize)]
pub struct UpdateMealBody {
    pub name: Option<String>,
    pub ingredients: Option<Vec<MealIngredientInput>>,
}

#[derive(Deserialize)]
pub struct LogMealBody {
    pub day: String,
    pub meal_period: String,
    pub meal_id: i64,
    pub percent: f64, // 0-100
}

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

fn kcal_from_macros(protein_g: f64, carbs_g: f64, fats_g: f64) -> i64 {
    #[allow(clippy::cast_possible_truncation)]
    (protein_g * 4.0 + carbs_g * 4.0 + fats_g * 9.0).round() as i64
}

async fn compute_meal_totals(pool: &sqlx::SqlitePool, meal_id: i64) -> AppResult<MealTotals> {
    #[derive(sqlx::FromRow)]
    struct Row {
        total_grams: f64,
        protein_g: f64,
        carbs_g: f64,
        fats_g: f64,
    }
    let row = sqlx::query_as::<_, Row>(
        "SELECT
            COALESCE(SUM(mi.grams), 0) AS total_grams,
            COALESCE(SUM(mi.grams * f.protein_per_100g / 100.0), 0) AS protein_g,
            COALESCE(SUM(mi.grams * f.carbs_per_100g / 100.0), 0) AS carbs_g,
            COALESCE(SUM(mi.grams * f.fats_per_100g / 100.0), 0) AS fats_g
         FROM meal_ingredients mi
         JOIN foods f ON f.id = mi.food_id
         WHERE mi.meal_id = ?",
    )
    .bind(meal_id)
    .fetch_one(pool)
    .await?;

    Ok(MealTotals {
        total_grams: row.total_grams,
        protein_g: row.protein_g,
        carbs_g: row.carbs_g,
        fats_g: row.fats_g,
        kcal: kcal_from_macros(row.protein_g, row.carbs_g, row.fats_g),
    })
}

/// # Errors
/// Returns an error if the database query fails.
pub async fn list_meals(
    State(state): State<AppState>,
    Query(pagination): Query<Pagination>,
) -> AppResult<Json<Vec<MealSummary>>> {
    let meals = sqlx::query_as::<_, MealSummary>(
        "SELECT
            m.id AS id,
            m.name AS name,
            COALESCE(SUM(mi.grams), 0) AS total_grams,
            COALESCE(SUM(mi.grams * f.protein_per_100g / 100.0), 0) AS protein_g,
            COALESCE(SUM(mi.grams * f.carbs_per_100g / 100.0), 0) AS carbs_g,
            COALESCE(SUM(mi.grams * f.fats_per_100g / 100.0), 0) AS fats_g,
            0 AS kcal
         FROM meals m
         LEFT JOIN meal_ingredients mi ON mi.meal_id = m.id
         LEFT JOIN foods f ON f.id = mi.food_id
         GROUP BY m.id
         ORDER BY m.name ASC
         LIMIT ? OFFSET ?",
    )
    .bind(pagination.limit)
    .bind(pagination.offset)
    .fetch_all(&state.pool)
    .await?;

    let out = meals
        .into_iter()
        .map(|m| MealSummary {
            kcal: kcal_from_macros(m.protein_g, m.carbs_g, m.fats_g),
            ..m
        })
        .collect();

    Ok(Json(out))
}

/// # Errors
/// Returns `NOT_FOUND` if the meal doesn't exist.
pub async fn get_meal(
    State(state): State<AppState>,
    Path(id): Path<i64>,
) -> AppResult<Json<MealDetail>> {
    #[derive(sqlx::FromRow)]
    struct MealRow {
        id: i64,
        name: String,
    }
    let meal = sqlx::query_as::<_, MealRow>("SELECT id, name FROM meals WHERE id = ?")
        .bind(id)
        .fetch_optional(&state.pool)
        .await?
        .ok_or(StatusCode::NOT_FOUND)?;

    let ingredients = sqlx::query_as::<_, MealIngredientDetail>(
        "SELECT
            mi.id AS id,
            mi.food_id AS food_id,
            f.name AS food_name,
            f.brand AS food_brand,
            f.protein_per_100g AS protein_per_100g,
            f.carbs_per_100g AS carbs_per_100g,
            f.fats_per_100g AS fats_per_100g,
            mi.grams AS grams,
            mi.position AS position
         FROM meal_ingredients mi
         JOIN foods f ON f.id = mi.food_id
         WHERE mi.meal_id = ?
         ORDER BY mi.position ASC, mi.id ASC",
    )
    .bind(id)
    .fetch_all(&state.pool)
    .await?;

    let totals = compute_meal_totals(&state.pool, id).await?;

    Ok(Json(MealDetail {
        id: meal.id,
        name: meal.name,
        ingredients,
        totals,
    }))
}

/// # Errors
/// Returns an error if validation fails or insert fails.
pub async fn create_meal(
    State(state): State<AppState>,
    Json(body): Json<CreateMealBody>,
) -> AppResult<(StatusCode, Json<MealDetail>)> {
    if body.name.trim().is_empty() {
        return Err((StatusCode::BAD_REQUEST, "name is required".to_string()).into());
    }
    if body.ingredients.is_empty() {
        return Err((
            StatusCode::BAD_REQUEST,
            "at least one ingredient is required".to_string(),
        )
            .into());
    }
    if body.ingredients.iter().any(|i| i.grams <= 0.0) {
        return Err((
            StatusCode::BAD_REQUEST,
            "ingredient grams must be > 0".to_string(),
        )
            .into());
    }

    let mut tx = state.pool.begin().await?;
    let meal_id: i64 = sqlx::query_scalar("INSERT INTO meals (name) VALUES (?) RETURNING id")
        .bind(body.name.trim())
        .fetch_one(&mut *tx)
        .await?;

    for (pos, ing) in body.ingredients.iter().enumerate() {
        sqlx::query(
            "INSERT INTO meal_ingredients (meal_id, food_id, grams, position) VALUES (?, ?, ?, ?)",
        )
        .bind(meal_id)
        .bind(ing.food_id)
        .bind(ing.grams)
        .bind(pos as i64)
        .execute(&mut *tx)
        .await?;
    }

    tx.commit().await?;
    let detail = get_meal(State(state), Path(meal_id)).await?.0;
    Ok((StatusCode::CREATED, Json(detail)))
}

/// # Errors
/// Returns `NOT_FOUND` if the meal doesn't exist.
pub async fn update_meal(
    State(state): State<AppState>,
    Path(id): Path<i64>,
    Json(body): Json<UpdateMealBody>,
) -> AppResult<Json<MealDetail>> {
    if body.name.as_ref().is_some_and(|n| n.trim().is_empty()) {
        return Err((StatusCode::BAD_REQUEST, "name cannot be empty".to_string()).into());
    }
    if body
        .ingredients
        .as_ref()
        .is_some_and(|ings| ings.iter().any(|i| i.grams <= 0.0))
    {
        return Err((
            StatusCode::BAD_REQUEST,
            "ingredient grams must be > 0".to_string(),
        )
            .into());
    }

    let mut tx = state.pool.begin().await?;
    let exists: Option<i64> = sqlx::query_scalar("SELECT id FROM meals WHERE id = ?")
        .bind(id)
        .fetch_optional(&mut *tx)
        .await?;
    if exists.is_none() {
        return Err(StatusCode::NOT_FOUND.into());
    }

    if let Some(name) = body.name {
        sqlx::query("UPDATE meals SET name = ?, updated_at = CURRENT_TIMESTAMP WHERE id = ?")
            .bind(name.trim())
            .bind(id)
            .execute(&mut *tx)
            .await?;
    }

    if let Some(ingredients) = body.ingredients {
        if ingredients.is_empty() {
            return Err((
                StatusCode::BAD_REQUEST,
                "at least one ingredient is required".to_string(),
            )
                .into());
        }
        sqlx::query("DELETE FROM meal_ingredients WHERE meal_id = ?")
            .bind(id)
            .execute(&mut *tx)
            .await?;
        for (pos, ing) in ingredients.iter().enumerate() {
            sqlx::query(
                "INSERT INTO meal_ingredients (meal_id, food_id, grams, position) VALUES (?, ?, ?, ?)",
            )
            .bind(id)
            .bind(ing.food_id)
            .bind(ing.grams)
            .bind(pos as i64)
            .execute(&mut *tx)
            .await?;
        }
        sqlx::query("UPDATE meals SET updated_at = CURRENT_TIMESTAMP WHERE id = ?")
            .bind(id)
            .execute(&mut *tx)
            .await?;
    }

    tx.commit().await?;
    Ok(get_meal(State(state), Path(id)).await?.0)
}

/// # Errors
/// Returns `NOT_FOUND` if the meal doesn't exist.
pub async fn delete_meal(
    State(state): State<AppState>,
    Path(id): Path<i64>,
) -> AppResult<StatusCode> {
    let res = sqlx::query("DELETE FROM meals WHERE id = ?")
        .bind(id)
        .execute(&state.pool)
        .await?;
    if res.rows_affected() == 0 {
        return Err(StatusCode::NOT_FOUND.into());
    }
    Ok(StatusCode::NO_CONTENT)
}

/// Log a meal to the daily tracker as a calorie entry. This snapshots meal macros
/// at log time (past logs won't change when the meal is edited).
///
/// # Errors
/// Returns validation errors or database errors.
pub async fn log_meal(
    State(state): State<AppState>,
    Json(body): Json<LogMealBody>,
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
    if !(0.0..=100.0).contains(&body.percent) || body.percent <= 0.0 {
        return Err((
            StatusCode::BAD_REQUEST,
            "percent must be > 0 and <= 100".to_string(),
        )
            .into());
    }

    #[derive(sqlx::FromRow)]
    struct MealRow {
        name: String,
    }
    let meal = sqlx::query_as::<_, MealRow>("SELECT name FROM meals WHERE id = ?")
        .bind(body.meal_id)
        .fetch_optional(&state.pool)
        .await?
        .ok_or(StatusCode::NOT_FOUND)?;

    let totals = compute_meal_totals(&state.pool, body.meal_id).await?;
    if totals.total_grams <= 0.0 {
        return Err((
            StatusCode::BAD_REQUEST,
            "meal has no ingredients".to_string(),
        )
            .into());
    }

    let factor = body.percent / 100.0;
    let weight_g = totals.total_grams * factor;
    let protein_g = totals.protein_g * factor;
    let carbs_g = totals.carbs_g * factor;
    let fats_g = totals.fats_g * factor;
    let kcal = kcal_from_macros(protein_g, carbs_g, fats_g);

    let protein_per_100g = totals.protein_g / totals.total_grams * 100.0;
    let carbs_per_100g = totals.carbs_g / totals.total_grams * 100.0;
    let fats_per_100g = totals.fats_g / totals.total_grams * 100.0;

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
    .bind(meal.name)
    .bind(protein_per_100g.max(0.0))
    .bind(carbs_per_100g.max(0.0))
    .bind(fats_per_100g.max(0.0))
    .bind(weight_g)
    .bind(protein_g)
    .bind(carbs_g)
    .bind(fats_g)
    .bind(kcal)
    .fetch_one(&state.pool)
    .await?;

    Ok((StatusCode::CREATED, Json(entry)))
}
