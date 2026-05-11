-- Extend foods catalog for better search + vegan-focused seed data.
-- Notes:
-- - We keep canonical name in English and store Polish/English synonyms in `aliases`.
-- - Values are per 100g; users can edit locally as needed.

ALTER TABLE foods ADD COLUMN is_vegan INTEGER NOT NULL DEFAULT 1;
ALTER TABLE foods ADD COLUMN aliases TEXT NOT NULL DEFAULT '';
ALTER TABLE foods ADD COLUMN tags TEXT NOT NULL DEFAULT '';
ALTER TABLE foods ADD COLUMN locale TEXT NOT NULL DEFAULT 'any';

CREATE INDEX IF NOT EXISTS idx_foods_aliases ON foods(aliases);
CREATE INDEX IF NOT EXISTS idx_foods_is_vegan ON foods(is_vegan);

-- Vegan produce (raw) + staples (common entries). Idempotent via ON CONFLICT(name, brand).
INSERT INTO foods (name, brand, protein_per_100g, carbs_per_100g, fats_per_100g, last_weight_g, source, is_vegan, aliases, tags, locale)
VALUES
  ('Banana', '', 1.1, 22.8, 0.3, 120, 'seed', 1, 'banana,banan', 'produce,fruit', 'any'),
  ('Apple', '', 0.3, 13.8, 0.2, 180, 'seed', 1, 'apple,jablko', 'produce,fruit', 'any'),
  ('Orange', '', 0.9, 11.8, 0.1, 180, 'seed', 1, 'orange,pomarancza,pomarancz', 'produce,fruit', 'any'),
  ('Tomato', '', 0.9, 3.9, 0.2, 120, 'seed', 1, 'tomato,pomidor', 'produce,vegetable', 'any'),
  ('Cucumber', '', 0.7, 3.6, 0.1, 150, 'seed', 1, 'cucumber,ogorek,ogorek', 'produce,vegetable', 'any'),
  ('Carrot', '', 0.9, 9.6, 0.2, 120, 'seed', 1, 'carrot,marchew', 'produce,vegetable', 'any'),
  ('Potato', '', 2.0, 17.0, 0.1, 250, 'seed', 1, 'potato,ziemniak', 'produce,vegetable', 'any'),
  ('Onion', '', 1.1, 9.3, 0.1, 80, 'seed', 1, 'onion,cebula', 'produce,vegetable', 'any'),
  ('Bell pepper', '', 1.0, 6.0, 0.3, 120, 'seed', 1, 'bell pepper,pepper,papryka', 'produce,vegetable', 'any'),
  ('Broccoli', '', 2.8, 6.6, 0.4, 150, 'seed', 1, 'broccoli,brokul', 'produce,vegetable', 'any'),
  ('Spinach', '', 2.9, 3.6, 0.4, 80, 'seed', 1, 'spinach,szpinak', 'produce,vegetable', 'any'),
  ('Mushrooms', '', 3.1, 3.3, 0.3, 120, 'seed', 1, 'mushrooms,pieczarki', 'produce,vegetable', 'any'),
  ('Blueberries', '', 0.7, 14.5, 0.3, 100, 'seed', 1, 'blueberries,jagody', 'produce,fruit', 'any'),
  ('Strawberries', '', 0.7, 7.7, 0.3, 150, 'seed', 1, 'strawberries, truskawki', 'produce,fruit', 'any'),
  ('Oats (dry)', '', 13.2, 67.7, 6.5, 80, 'seed', 1, 'oats,platki owsiane,owsianka', 'staple,grain', 'any'),
  ('Rice (cooked)', '', 2.4, 28.2, 0.3, 200, 'seed', 1, 'rice,ryz', 'staple,grain', 'any'),
  ('Lentils (cooked)', '', 9.0, 20.1, 0.4, 200, 'seed', 1, 'lentils,soczewica', 'staple,legume', 'any'),
  ('Chickpeas (cooked)', '', 8.9, 27.4, 2.6, 180, 'seed', 1, 'chickpeas,ciecierzyca', 'staple,legume', 'any'),
  ('Tofu, firm', '', 17.3, 2.8, 8.7, 150, 'seed', 1, 'tofu', 'protein,soy', 'any')
ON CONFLICT(name, brand) DO UPDATE SET
  protein_per_100g = excluded.protein_per_100g,
  carbs_per_100g = excluded.carbs_per_100g,
  fats_per_100g = excluded.fats_per_100g,
  last_weight_g = excluded.last_weight_g,
  source = excluded.source,
  is_vegan = excluded.is_vegan,
  aliases = excluded.aliases,
  tags = excluded.tags,
  locale = excluded.locale;

