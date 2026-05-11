ALTER TABLE calorie_entries ADD COLUMN protein_per_100g REAL NOT NULL DEFAULT 0;
ALTER TABLE calorie_entries ADD COLUMN carbs_per_100g REAL NOT NULL DEFAULT 0;
ALTER TABLE calorie_entries ADD COLUMN fats_per_100g REAL NOT NULL DEFAULT 0;
ALTER TABLE calorie_entries ADD COLUMN weight_g REAL NOT NULL DEFAULT 100;

UPDATE calorie_entries
SET
    protein_per_100g = protein_g,
    carbs_per_100g = carbs_g,
    fats_per_100g = fats_g,
    weight_g = 100
WHERE weight_g = 100
  AND protein_per_100g = 0
  AND carbs_per_100g = 0
  AND fats_per_100g = 0;
