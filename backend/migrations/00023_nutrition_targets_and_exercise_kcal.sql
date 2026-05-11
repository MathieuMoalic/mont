CREATE TABLE nutrition_targets (
    id        INTEGER PRIMARY KEY CHECK (id = 1),
    protein_g REAL NOT NULL CHECK (protein_g >= 0),
    carbs_g   REAL NOT NULL CHECK (carbs_g >= 0),
    fats_g    REAL NOT NULL CHECK (fats_g >= 0)
);

CREATE TABLE calorie_exercises (
    id   INTEGER PRIMARY KEY AUTOINCREMENT,
    day  TEXT    NOT NULL,
    name TEXT    NOT NULL,
    kcal INTEGER NOT NULL CHECK (kcal >= 0)
);

CREATE INDEX idx_calorie_exercises_day ON calorie_exercises(day);
