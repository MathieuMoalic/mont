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
pub struct Food {
    pub id: i64,
    pub name: String,
    pub brand: String,
    pub protein_per_100g: f64,
    pub carbs_per_100g: f64,
    pub fats_per_100g: f64,
    pub last_weight_g: f64,
    pub source: String,
}

#[derive(Serialize)]
pub struct FoodLookupResult {
    pub name: String,
    pub brand: String,
    pub protein_per_100g: f64,
    pub carbs_per_100g: f64,
    pub fats_per_100g: f64,
    pub source: String,
}

#[derive(Deserialize)]
pub struct ListCaloriesQuery {
    pub start: String,
    pub end: String,
}

#[derive(Deserialize)]
pub struct FoodSearchQuery {
    pub q: Option<String>,
    pub limit: Option<i64>,
}

#[derive(Deserialize)]
pub struct LookupFoodsQuery {
    pub q: String,
    pub limit: Option<usize>,
}

#[derive(Deserialize)]
pub struct UpsertFoodBody {
    pub name: String,
    pub brand: Option<String>,
    pub protein_per_100g: f64,
    pub carbs_per_100g: f64,
    pub fats_per_100g: f64,
    pub last_weight_g: f64,
    pub source: Option<String>,
}

#[derive(Deserialize)]
pub struct ExtractMacrosQuery {
    pub q: String,
    #[serde(default)]
    pub data_type: Option<String>,
}

#[derive(Serialize, Deserialize)]
pub struct ExtractMacrosResponse {
    pub name: String,
    pub protein_per_100g: f64,
    pub carbs_per_100g: f64,
    pub fats_per_100g: f64,
    pub source: String,
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

fn validate_barcode(barcode: &str) -> bool {
    let b = barcode.trim();
    (8..=14).contains(&b.len()) && b.as_bytes().iter().all(u8::is_ascii_digit)
}

#[allow(clippy::too_many_arguments)]
async fn upsert_food_by_name_brand(
    pool: &sqlx::SqlitePool,
    name: &str,
    brand: &str,
    protein_per_100g: f64,
    carbs_per_100g: f64,
    fats_per_100g: f64,
    last_weight_g: f64,
    source: &str,
) -> AppResult<()> {
    sqlx::query(
        "INSERT INTO foods (name, brand, protein_per_100g, carbs_per_100g, fats_per_100g, last_weight_g, source)
         VALUES (?, ?, ?, ?, ?, ?, ?)
         ON CONFLICT(name, brand) DO UPDATE SET
            protein_per_100g = excluded.protein_per_100g,
            carbs_per_100g = excluded.carbs_per_100g,
            fats_per_100g = excluded.fats_per_100g,
            last_weight_g = excluded.last_weight_g,
            source = excluded.source",
    )
    .bind(name)
    .bind(brand)
    .bind(protein_per_100g)
    .bind(carbs_per_100g)
    .bind(fats_per_100g)
    .bind(last_weight_g)
    .bind(source)
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
pub async fn list_foods(
    State(state): State<AppState>,
    Query(query): Query<FoodSearchQuery>,
) -> AppResult<Json<Vec<Food>>> {
    let limit = query.limit.unwrap_or(100).clamp(1, 200);

    let foods = if let Some(q) = query.q.as_deref() {
        let term = q.trim();
        sqlx::query_as::<_, Food>(
            "SELECT id, name, brand, protein_per_100g, carbs_per_100g, fats_per_100g, last_weight_g, source
             FROM foods
             WHERE name LIKE '%' || ? || '%'
                OR aliases LIKE '%' || ? || '%'
             ORDER BY name ASC
             LIMIT ?",
        )
        .bind(term)
        .bind(term)
        .bind(limit)
        .fetch_all(&state.pool)
        .await?
    } else {
        sqlx::query_as::<_, Food>(
            "SELECT id, name, brand, protein_per_100g, carbs_per_100g, fats_per_100g, last_weight_g, source
             FROM foods
             ORDER BY name ASC
             LIMIT ?",
        )
        .bind(limit)
        .fetch_all(&state.pool)
        .await?
    };
    Ok(Json(foods))
}

/// # Errors
/// Returns an error if the barcode is invalid or the query fails.
pub async fn get_food_by_barcode(
    State(state): State<AppState>,
    Path(barcode): Path<String>,
) -> AppResult<Json<Food>> {
    if !validate_barcode(&barcode) {
        return Err((
            StatusCode::BAD_REQUEST,
            "barcode must be 8-14 digits".to_string(),
        )
            .into());
    }

    let food = sqlx::query_as::<_, Food>(
        "SELECT f.id, f.name, f.brand, f.protein_per_100g, f.carbs_per_100g, f.fats_per_100g, f.last_weight_g, f.source
         FROM food_barcodes b
         JOIN foods f ON f.id = b.food_id
         WHERE b.barcode = ?",
    )
    .bind(barcode.trim())
    .fetch_optional(&state.pool)
    .await?;

    let Some(food) = food else {
        return Err((StatusCode::NOT_FOUND, "barcode not found".to_string()).into());
    };
    Ok(Json(food))
}

#[derive(Deserialize)]
struct OpenFoodFactsResp {
    status: i64,
    product: Option<OpenFoodFactsProduct>,
}

#[derive(Deserialize)]
struct OpenFoodFactsProduct {
    product_name: Option<String>,
    product_name_pl: Option<String>,
    brands: Option<String>,
    nutriments: Option<OpenFoodFactsNutriments>,
}

#[derive(Deserialize)]
struct OpenFoodFactsNutriments {
    #[serde(rename = "proteins_100g")]
    proteins: Option<f64>,
    #[serde(rename = "carbohydrates_100g")]
    carbohydrates: Option<f64>,
    #[serde(rename = "fat_100g")]
    fat: Option<f64>,
}

async fn fetch_open_food_facts_pl(
    http: &reqwest::Client,
    barcode: &str,
) -> Option<FoodLookupResult> {
    let url = format!(
        "https://world.openfoodfacts.org/api/v2/product/{barcode}\
?fields=product_name,product_name_pl,brands,nutriments\
&lc=pl&cc=pl"
    );

    let resp = http
        .get(url)
        .timeout(std::time::Duration::from_secs(10))
        .send()
        .await
        .ok()?;

    if !resp.status().is_success() {
        return None;
    }

    let body: OpenFoodFactsResp = resp.json().await.ok()?;
    if body.status != 1 {
        return None;
    }
    let product = body.product?;
    let nutr = product.nutriments?;

    let protein = nutr.proteins?;
    let carbs = nutr.carbohydrates?;
    let fats = nutr.fat?;

    let name = product
        .product_name_pl
        .or(product.product_name)
        .unwrap_or_else(|| "Unknown product".to_string())
        .trim()
        .to_string();

    let brand = product
        .brands
        .unwrap_or_default()
        .split(',')
        .next()
        .unwrap_or_default()
        .trim()
        .to_string();

    Some(FoodLookupResult {
        name,
        brand,
        protein_per_100g: protein.max(0.0),
        carbs_per_100g: carbs.max(0.0),
        fats_per_100g: fats.max(0.0),
        source: "open_food_facts".to_string(),
    })
}

#[derive(Deserialize)]
struct OpenFoodFactsSearchResp {
    products: Vec<OpenFoodFactsProduct>,
}

/// # Errors
/// Returns an error if the barcode is invalid or the external lookup fails.
pub async fn lookup_food_by_barcode(
    State(state): State<AppState>,
    Path(barcode): Path<String>,
) -> AppResult<Json<FoodLookupResult>> {
    if !validate_barcode(&barcode) {
        return Err((
            StatusCode::BAD_REQUEST,
            "barcode must be 8-14 digits".to_string(),
        )
            .into());
    }

    let Some(found) = fetch_open_food_facts_pl(&state.http, barcode.trim()).await else {
        return Err((StatusCode::NOT_FOUND, "not found".to_string()).into());
    };
    Ok(Json(found))
}

/// Lookup foods by free-text query: searches local DB first, then falls back to Open Food Facts.
///
/// Returns local database results first (faster), then online results from Open Food Facts.
/// Deduplicates based on name to avoid showing the same food twice.
///
/// # Errors
/// Returns an error if the query is empty. Network errors are logged but don't fail the request
/// if local results are found.
#[allow(clippy::cast_possible_wrap, clippy::cast_possible_truncation, clippy::too_many_lines)]
pub async fn lookup_foods_by_query(
    State(state): State<AppState>,
    Query(query): Query<LookupFoodsQuery>,
) -> AppResult<Json<Vec<FoodLookupResult>>> {
    let term = query.q.trim();
    if term.is_empty() {
        return Err((StatusCode::BAD_REQUEST, "q is required".to_string()).into());
    }
    let limit = query.limit.unwrap_or(10).clamp(1, 20);

    // 1. Search local database first
    let local_foods = sqlx::query_as::<_, Food>(
        "SELECT id, name, brand, protein_per_100g, carbs_per_100g, fats_per_100g, last_weight_g, source
         FROM foods
         WHERE name LIKE '%' || ? || '%'
            OR aliases LIKE '%' || ? || '%'
         ORDER BY name ASC
         LIMIT ?",
    )
    .bind(term)
    .bind(term)
    .bind(limit as i64)
    .fetch_all(&state.pool)
    .await?;

    let mut out: Vec<FoodLookupResult> = local_foods
        .into_iter()
        .map(|f| FoodLookupResult {
            name: f.name,
            brand: f.brand,
            protein_per_100g: f.protein_per_100g,
            carbs_per_100g: f.carbs_per_100g,
            fats_per_100g: f.fats_per_100g,
            source: f.source,
        })
        .collect();

    // 2. If we have enough local results, return early (avoid unnecessary network call)
    if out.len() >= limit {
        return Ok(Json(out));
    }

    // 3. Fallback to Open Food Facts for additional results
    let remaining_limit = limit - out.len();
    let mut url = reqwest::Url::parse("https://world.openfoodfacts.org/api/v2/search")
        .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, format!("Bad OFF url: {e}")))?;
    url.query_pairs_mut()
        .append_pair("search_terms", term)
        .append_pair(
            "fields",
            "product_name,product_name_pl,brands,nutriments",
        )
        .append_pair("lc", "pl")
        .append_pair("cc", "pl")
        .append_pair("page_size", &remaining_limit.to_string());

    let resp = match state
        .http
        .get(url)
        .timeout(std::time::Duration::from_secs(10))
        .send()
        .await
    {
        Ok(r) => r,
        Err(e) => {
            // Log but don't fail - user can still manually enter macros
            tracing::warn!("Open Food Facts request failed: {}", e);
            return Ok(Json(out));
        }
    };

    if !resp.status().is_success() {
        // Same here - graceful degradation, user can manual entry
        tracing::warn!("Open Food Facts returned HTTP {}", resp.status());
        return Ok(Json(out));
    }

    let body: OpenFoodFactsSearchResp = match resp.json().await {
        Ok(b) => b,
        Err(e) => {
            tracing::warn!("Open Food Facts JSON parse failed: {}", e);
            return Ok(Json(out));
        }
    };

    // 4. Extract names of already-added items to avoid duplicates
    let local_names: std::collections::HashSet<String> =
        out.iter().map(|f| f.name.to_lowercase()).collect();

    // 5. Add online results that don't duplicate local ones
    for p in body.products {
        if out.len() >= limit {
            break;
        }

        let Some(nutr) = p.nutriments else { continue };
        let (Some(protein), Some(carbs), Some(fats)) = (
            nutr.proteins,
            nutr.carbohydrates,
            nutr.fat,
        ) else {
            continue;
        };
        let name = p
            .product_name_pl
            .or(p.product_name)
            .unwrap_or_default()
            .trim()
            .to_string();
        if name.is_empty() {
            continue;
        }

        // Skip if already in local results
        if local_names.contains(&name.to_lowercase()) {
            continue;
        }

        let brand = p
            .brands
            .unwrap_or_default()
            .split(',')
            .next()
            .unwrap_or_default()
            .trim()
            .to_string();

        out.push(FoodLookupResult {
            name,
            brand,
            protein_per_100g: protein.max(0.0),
            carbs_per_100g: carbs.max(0.0),
            fats_per_100g: fats.max(0.0),
            source: "open_food_facts".to_string(),
        });
    }

    Ok(Json(out))
}

/// # Errors
/// Returns an error if validation fails or the upsert fails.
pub async fn upsert_food_by_barcode(
    State(state): State<AppState>,
    Path(barcode): Path<String>,
    Json(body): Json<UpsertFoodBody>,
) -> AppResult<Json<Food>> {
    if !validate_barcode(&barcode) {
        return Err((
            StatusCode::BAD_REQUEST,
            "barcode must be 8-14 digits".to_string(),
        )
            .into());
    }
    if body.name.trim().is_empty() {
        return Err((
            StatusCode::BAD_REQUEST,
            "Food name cannot be empty".to_string(),
        )
            .into());
    }
    if body.protein_per_100g < 0.0
        || body.carbs_per_100g < 0.0
        || body.fats_per_100g < 0.0
        || body.last_weight_g <= 0.0
    {
        return Err((
            StatusCode::BAD_REQUEST,
            "Per-100g macros must be non-negative and last_weight_g must be > 0".to_string(),
        )
            .into());
    }

    let brand = body.brand.unwrap_or_default().trim().to_string();
    let source = body.source.unwrap_or_else(|| "manual".to_string());

    // Create or update the food row, then map the barcode.
    let food = sqlx::query_as::<_, Food>(
        "INSERT INTO foods (name, brand, protein_per_100g, carbs_per_100g, fats_per_100g, last_weight_g, source)
         VALUES (?, ?, ?, ?, ?, ?, ?)
         ON CONFLICT(name, brand) DO UPDATE SET
            protein_per_100g = excluded.protein_per_100g,
            carbs_per_100g = excluded.carbs_per_100g,
            fats_per_100g = excluded.fats_per_100g,
            last_weight_g = excluded.last_weight_g,
            source = excluded.source
         RETURNING id, name, brand, protein_per_100g, carbs_per_100g, fats_per_100g, last_weight_g, source",
    )
    .bind(body.name.trim())
    .bind(brand.as_str())
    .bind(body.protein_per_100g)
    .bind(body.carbs_per_100g)
    .bind(body.fats_per_100g)
    .bind(body.last_weight_g)
    .bind(source.as_str())
    .fetch_one(&state.pool)
    .await?;

    sqlx::query(
        "INSERT INTO food_barcodes (barcode, food_id, source, last_seen)
         VALUES (?, ?, ?, strftime('%Y-%m-%dT%H:%M:%fZ','now'))
         ON CONFLICT(barcode) DO UPDATE SET
            food_id = excluded.food_id,
            source = excluded.source,
            last_seen = excluded.last_seen",
    )
    .bind(barcode.trim())
    .bind(food.id)
    .bind(source.as_str())
    .execute(&state.pool)
    .await?;

    Ok(Json(food))
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
    upsert_food_by_name_brand(
        &state.pool,
        entry.name.as_str(),
        "",
        entry.protein_per_100g,
        entry.carbs_per_100g,
        entry.fats_per_100g,
        entry.weight_g,
        "from_entry",
    )
    .await?;

    Ok((StatusCode::CREATED, Json(entry)))
}

/// # Errors
/// Returns `NOT_FOUND` if the entry doesn't exist or validation fails.
#[allow(clippy::too_many_lines)]
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
    upsert_food_by_name_brand(
        &state.pool,
        entry.name.as_str(),
        "",
        entry.protein_per_100g,
        entry.carbs_per_100g,
        entry.fats_per_100g,
        entry.weight_g,
        "from_entry",
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

#[allow(clippy::too_many_lines)]
/// Extract food macros using USDA API first, then LLM as fallback.
///
/// # Errors
/// Returns error if food name is empty or both USDA and LLM lookups fail.
pub async fn extract_macros_with_llm(
    State(state): State<AppState>,
    Query(query): Query<ExtractMacrosQuery>,
) -> AppResult<Json<ExtractMacrosResponse>> {
    const USDA_API_URL: &str = "https://api.nal.usda.gov/fdc/v1";
    
    let food_name = query.q.trim();
    if food_name.is_empty() {
        return Err((
            StatusCode::BAD_REQUEST,
            "Food name cannot be empty".to_string(),
        )
            .into());
    }

    // Try USDA API first if configured
    if let Some(usda_key) = &state.config.usda_api_key {
        let data_type = query.data_type.as_deref().unwrap_or("Foundation");
        match lookup_usda_food(food_name, usda_key, USDA_API_URL, data_type).await {
            Ok(result) => {
                tracing::info!("Successfully extracted macros from USDA ({data_type}) for: {food_name}");
                return Ok(Json(result));
            }
            Err(e) => {
                tracing::debug!("USDA ({data_type}) lookup failed, falling back to LLM: {e:?}");
            }
        }
    } else {
        tracing::debug!("USDA API key not configured, using LLM only");
    }

    // Fall back to LLM
    let llm_key = state
        .config
        .llm_api_key
        .as_ref()
        .ok_or_else(|| {
            (
                StatusCode::SERVICE_UNAVAILABLE,
                "No nutrition data source available (USDA and LLM both unavailable)".to_string(),
            )
        })?;

    tracing::info!("Using LLM to extract macros for: {food_name}");
    lookup_llm_food(food_name, llm_key, &state.config.llm_api_url, &state.config.llm_model).await
}

async fn lookup_usda_food(
    food_name: &str,
    api_key: &str,
    api_url: &str,
    data_type: &str,
) -> AppResult<ExtractMacrosResponse> {
    tracing::debug!("Looking up food in USDA ({data_type}): {food_name}");
    
    let client = reqwest::Client::new();
    let url = format!("{}/foods/search", api_url.trim_end_matches('/'));
    
    let response = client
        .get(&url)
        .query(&[
            ("query", food_name),
            ("api_key", api_key),
            ("dataType", data_type),
            ("pageSize", "1"),
        ])
        .send()
        .await
        .map_err(|e| {
            tracing::error!("USDA API request failed: {e}");
            (
                StatusCode::BAD_GATEWAY,
                format!("USDA API request failed: {e}"),
            )
        })?;

    let status = response.status();
    tracing::debug!("USDA API response status: {status}");

    if !status.is_success() {
        let error_text = response.text().await.unwrap_or_default();
        let truncated = if error_text.len() > 200 {
            format!("{}...", &error_text[..200])
        } else {
            error_text
        };
        tracing::warn!("USDA API returned error ({data_type}): {truncated}");
        return Err((
            StatusCode::BAD_GATEWAY,
            "USDA API returned an error".to_string(),
        )
            .into());
    }

    let body: serde_json::Value = response.json().await.map_err(|e| {
        tracing::error!("Failed to parse USDA response as JSON: {e}");
        (
            StatusCode::BAD_GATEWAY,
            format!("Failed to parse USDA response: {e}"),
        )
    })?;

    tracing::debug!("USDA response parsed successfully");

    let foods = body
        .get("foods")
        .and_then(|f| f.as_array())
        .ok_or_else(|| {
            tracing::warn!("Invalid USDA response format: missing or invalid 'foods' array");
            (
                StatusCode::BAD_GATEWAY,
                "Invalid USDA response format".to_string(),
            )
        })?;

    if foods.is_empty() {
        tracing::info!("No foods found in USDA ({data_type}) for query: {food_name}");
        return Err((
            StatusCode::NOT_FOUND,
            format!("No foods found in USDA {data_type} database"),
        )
            .into());
    }

    let food = &foods[0];
    let food_name = food
        .get("description")
        .and_then(|d| d.as_str())
        .unwrap_or("Food");

    tracing::debug!("Found food in USDA ({data_type}): {food_name}");

    let nutrients = food
        .get("foodNutrients")
        .and_then(|n| n.as_array())
        .ok_or_else(|| {
            (
                StatusCode::BAD_GATEWAY,
                "No nutrients found in USDA food data".to_string(),
            )
        })?;

    let mut protein = 0.0;
    let mut carbs = 0.0;
    let mut fats = 0.0;

    for nutrient in nutrients {
        let nutrient_id = nutrient.get("nutrientId").and_then(serde_json::Value::as_i64);
        let value = nutrient.get("value").and_then(serde_json::Value::as_f64).unwrap_or(0.0);

        match nutrient_id {
            Some(1003) => protein = value, // Protein
            Some(1005) => carbs = value,   // Carbohydrate
            Some(1004) => fats = value,    // Fat
            _ => {}
        }
    }

    Ok(ExtractMacrosResponse {
        name: food_name.to_string(),
        protein_per_100g: protein,
        carbs_per_100g: carbs,
        fats_per_100g: fats,
        source: format!("usda_{}", data_type.to_lowercase()),
    })
}

#[allow(clippy::too_many_lines)]
async fn lookup_llm_food(
    food_name: &str,
    api_key: &str,
    api_url: &str,
    model: &str,
) -> AppResult<Json<ExtractMacrosResponse>> {
    let prompt = format!(
        "Extract nutritional macros for: {food_name}\n\nRespond with ONLY a JSON object with these fields (numbers only, per 100g):\n{{\n  \"name\": \"food name\",\n  \"protein_per_100g\": <number>,\n  \"carbs_per_100g\": <number>,\n  \"fats_per_100g\": <number>\n}}\n\nExample:\n{{\n  \"name\": \"white rice uncooked\",\n  \"protein_per_100g\": 6.6,\n  \"carbs_per_100g\": 79.3,\n  \"fats_per_100g\": 0.3\n}}"
    );

    let client = reqwest::Client::new();
    let url = format!("{}/chat/completions", api_url.trim_end_matches('/'));
    tracing::debug!("Calling LLM API at: {url}");
    
    let response = client
        .post(&url)
        .bearer_auth(api_key)
        .json(&serde_json::json!({
            "model": model,
            "messages": [
                {"role": "user", "content": prompt}
            ],
            "temperature": 0.1,
            "response_format": { "type": "json_object" }
        }))
        .send()
        .await
        .map_err(|e| {
            tracing::error!("LLM API request failed: {e}");
            (
                StatusCode::BAD_GATEWAY,
                format!("LLM API request failed: {e}"),
            )
        })?;

    if !response.status().is_success() {
        let status = response.status();
        let error_text = response.text().await.unwrap_or_default();
        let truncated = if error_text.len() > 200 {
            format!("{}...", &error_text[..200])
        } else {
            error_text
        };
        tracing::warn!("LLM API returned error status {status}: {truncated}");
        return Err((
            StatusCode::BAD_GATEWAY,
            "LLM API returned an error".to_string(),
        )
            .into());
    }

    let body: serde_json::Value = response.json().await.map_err(|e| {
        tracing::error!("Failed to parse LLM response as JSON: {e}");
        (
            StatusCode::BAD_GATEWAY,
            format!("Failed to parse LLM response: {e}"),
        )
    })?;

    let content = body
        .get("choices")
        .and_then(|c| c.get(0))
        .and_then(|c| c.get("message"))
        .and_then(|m| m.get("content"))
        .and_then(|c| c.as_str())
        .ok_or_else(|| {
            tracing::error!("LLM response missing content field, structure: {:?}", body);
            (
                StatusCode::BAD_GATEWAY,
                "Invalid LLM response format".to_string(),
            )
        })?;

    let json_str = content
        .find('{')
        .and_then(|start| {
            content[start..]
                .rfind('}')
                .map(|end| &content[start..=(start + end)])
        })
        .ok_or_else(|| {
            (
                StatusCode::BAD_GATEWAY,
                "Could not extract JSON from LLM response".to_string(),
            )
        })?;

    let macros: ExtractMacrosResponse = serde_json::from_str(json_str).map_err(|e| {
        tracing::error!("Failed to parse macros JSON: {e}. Raw JSON: {json_str}");
        (
            StatusCode::BAD_GATEWAY,
            format!("Failed to parse macros from LLM response: {e}"),
        )
    })?;

    // Validate macros are non-negative and reasonable
    if macros.protein_per_100g < 0.0
        || macros.carbs_per_100g < 0.0
        || macros.fats_per_100g < 0.0
    {
        return Err((
            StatusCode::BAD_GATEWAY,
            "LLM returned negative macro values".to_string(),
        )
            .into());
    }

    if macros.protein_per_100g > 100.0
        || macros.carbs_per_100g > 100.0
        || macros.fats_per_100g > 100.0
    {
        return Err((
            StatusCode::BAD_GATEWAY,
            "LLM returned unrealistic macro values (>100g per 100g)".to_string(),
        )
            .into());
    }

    let mut response = macros;
    response.source = "llm".to_string();
    Ok(Json(response))
}

