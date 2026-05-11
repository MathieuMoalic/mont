CREATE TABLE calorie_entries (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    day         TEXT    NOT NULL,
    meal_period TEXT    NOT NULL CHECK (meal_period IN ('morning', 'afternoon', 'evening')),
    name        TEXT    NOT NULL,
    protein_g   REAL    NOT NULL CHECK (protein_g >= 0),
    carbs_g     REAL    NOT NULL CHECK (carbs_g >= 0),
    fats_g      REAL    NOT NULL CHECK (fats_g >= 0),
    kcal        INTEGER NOT NULL CHECK (kcal >= 0)
);

CREATE INDEX idx_calorie_entries_day ON calorie_entries(day);
