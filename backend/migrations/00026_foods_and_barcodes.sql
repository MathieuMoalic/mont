-- Dedicated foods table (normalized per-100g macros) + barcode mapping.
-- Keeps the DB offline-first: once a barcode is resolved, it is cached locally.

CREATE TABLE foods (
    id               INTEGER PRIMARY KEY AUTOINCREMENT,
    name             TEXT    NOT NULL,
    brand            TEXT    NOT NULL DEFAULT '',
    protein_per_100g REAL    NOT NULL CHECK (protein_per_100g >= 0),
    carbs_per_100g   REAL    NOT NULL CHECK (carbs_per_100g >= 0),
    fats_per_100g    REAL    NOT NULL CHECK (fats_per_100g >= 0),
    last_weight_g    REAL    NOT NULL CHECK (last_weight_g > 0),
    source           TEXT    NOT NULL DEFAULT 'manual',
    UNIQUE(name, brand)
);

CREATE INDEX idx_foods_name ON foods(name);

CREATE TABLE food_barcodes (
    barcode    TEXT    PRIMARY KEY,
    food_id    INTEGER NOT NULL REFERENCES foods(id) ON DELETE CASCADE,
    last_seen  TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
    source     TEXT    NOT NULL DEFAULT 'manual'
);

-- Best-effort migration from previous cache table.
INSERT INTO foods (name, protein_per_100g, carbs_per_100g, fats_per_100g, last_weight_g, source)
SELECT name, protein_per_100g, carbs_per_100g, fats_per_100g, last_weight_g, 'migrated'
FROM saved_foods
WHERE EXISTS (SELECT 1 FROM sqlite_master WHERE type='table' AND name='saved_foods');
