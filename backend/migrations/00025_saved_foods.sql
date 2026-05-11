CREATE TABLE saved_foods (
    id               INTEGER PRIMARY KEY AUTOINCREMENT,
    name             TEXT    NOT NULL UNIQUE,
    protein_per_100g REAL    NOT NULL CHECK (protein_per_100g >= 0),
    carbs_per_100g   REAL    NOT NULL CHECK (carbs_per_100g >= 0),
    fats_per_100g    REAL    NOT NULL CHECK (fats_per_100g >= 0),
    last_weight_g    REAL    NOT NULL CHECK (last_weight_g > 0)
);
