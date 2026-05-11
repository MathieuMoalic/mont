-- Vegan fruits + vegetables seed list (per 100g), with EN+PL aliases.
-- Safe to run multiple times (upserts by (name, brand)).
--
-- Note: These values are "typical raw" macros per 100g; treat as a starting point.

INSERT INTO foods (
  name, brand,
  protein_per_100g, carbs_per_100g, fats_per_100g,
  last_weight_g, source,
  is_vegan, aliases, tags, locale
)
VALUES
  -- Fruits
  ('Apple', '', 0.3, 13.8, 0.2, 180, 'seed_script', 1, 'apple,jablko,jabłko', 'produce,fruit', 'any'),
  ('Apricot', '', 1.4, 11.1, 0.4, 120, 'seed_script', 1, 'apricot,morela', 'produce,fruit', 'any'),
  ('Avocado', '', 2.0, 8.5, 14.7, 100, 'seed_script', 1, 'avocado,awokado', 'produce,fruit', 'any'),
  ('Banana', '', 1.1, 22.8, 0.3, 120, 'seed_script', 1, 'banana,banan', 'produce,fruit', 'any'),
  ('Blackberries', '', 1.4, 9.6, 0.5, 100, 'seed_script', 1, 'blackberries,jeżyny,jezyny', 'produce,fruit', 'any'),
  ('Blueberries', '', 0.7, 14.5, 0.3, 100, 'seed_script', 1, 'blueberries,jagody,borowki,borówki', 'produce,fruit', 'any'),
  ('Cherries', '', 1.1, 16.0, 0.2, 100, 'seed_script', 1, 'cherries,wiśnie,wisnie,czeresnie,czereśnie', 'produce,fruit', 'any'),
  ('Clementine', '', 0.9, 12.0, 0.2, 120, 'seed_script', 1, 'clementine,klementynka', 'produce,fruit', 'any'),
  ('Cranberries', '', 0.4, 12.2, 0.1, 100, 'seed_script', 1, 'cranberries,żurawina,zurawina', 'produce,fruit', 'any'),
  ('Dates (dried)', '', 2.5, 75.0, 0.4, 60, 'seed_script', 1, 'dates,daktyle', 'produce,fruit', 'any'),
  ('Grapes', '', 0.7, 18.1, 0.2, 150, 'seed_script', 1, 'grapes,winogrona', 'produce,fruit', 'any'),
  ('Grapefruit', '', 0.8, 8.1, 0.1, 200, 'seed_script', 1, 'grapefruit,grejpfrut', 'produce,fruit', 'any'),
  ('Kiwi', '', 1.1, 14.7, 0.5, 120, 'seed_script', 1, 'kiwi', 'produce,fruit', 'any'),
  ('Lemon', '', 1.1, 9.3, 0.3, 60, 'seed_script', 1, 'lemon,cytryna', 'produce,fruit', 'any'),
  ('Mango', '', 0.8, 15.0, 0.4, 150, 'seed_script', 1, 'mango', 'produce,fruit', 'any'),
  ('Melon', '', 0.8, 8.2, 0.2, 200, 'seed_script', 1, 'melon', 'produce,fruit', 'any'),
  ('Orange', '', 0.9, 11.8, 0.1, 180, 'seed_script', 1, 'orange,pomarancza,pomarańcza', 'produce,fruit', 'any'),
  ('Peach', '', 0.9, 9.5, 0.3, 150, 'seed_script', 1, 'peach,brzoskwinia', 'produce,fruit', 'any'),
  ('Pear', '', 0.4, 15.2, 0.1, 180, 'seed_script', 1, 'pear,gruszka', 'produce,fruit', 'any'),
  ('Pineapple', '', 0.5, 13.1, 0.1, 180, 'seed_script', 1, 'pineapple,ananas', 'produce,fruit', 'any'),
  ('Plum', '', 0.7, 11.4, 0.3, 120, 'seed_script', 1, 'plum,śliwka,śliwki,sliwka,sliwki', 'produce,fruit', 'any'),
  ('Raspberries', '', 1.2, 11.9, 0.7, 100, 'seed_script', 1, 'raspberries,maliny', 'produce,fruit', 'any'),
  ('Strawberries', '', 0.7, 7.7, 0.3, 150, 'seed_script', 1, 'strawberries,truskawki', 'produce,fruit', 'any'),
  ('Watermelon', '', 0.6, 7.6, 0.2, 250, 'seed_script', 1, 'watermelon,arbuz', 'produce,fruit', 'any'),

  -- Vegetables
  ('Asparagus', '', 2.2, 3.9, 0.1, 120, 'seed_script', 1, 'asparagus,szparagi', 'produce,vegetable', 'any'),
  ('Beetroot', '', 1.6, 10.0, 0.2, 150, 'seed_script', 1, 'beetroot,beet,burak,buraki', 'produce,vegetable', 'any'),
  ('Bell pepper', '', 1.0, 6.0, 0.3, 120, 'seed_script', 1, 'bell pepper,pepper,papryka', 'produce,vegetable', 'any'),
  ('Broccoli', '', 2.8, 6.6, 0.4, 150, 'seed_script', 1, 'broccoli,brokuł,brokul', 'produce,vegetable', 'any'),
  ('Brussels sprouts', '', 3.4, 9.0, 0.3, 150, 'seed_script', 1, 'brussels sprouts,brukselka', 'produce,vegetable', 'any'),
  ('Cabbage', '', 1.3, 5.8, 0.1, 180, 'seed_script', 1, 'cabbage,kapusta', 'produce,vegetable', 'any'),
  ('Carrot', '', 0.9, 9.6, 0.2, 120, 'seed_script', 1, 'carrot,marchew', 'produce,vegetable', 'any'),
  ('Cauliflower', '', 1.9, 5.0, 0.3, 180, 'seed_script', 1, 'cauliflower,kalafior', 'produce,vegetable', 'any'),
  ('Celery', '', 0.7, 3.0, 0.2, 120, 'seed_script', 1, 'celery,seler', 'produce,vegetable', 'any'),
  ('Corn (sweet)', '', 3.4, 19.0, 1.2, 160, 'seed_script', 1, 'corn,kukurydza', 'produce,vegetable', 'any'),
  ('Cucumber', '', 0.7, 3.6, 0.1, 150, 'seed_script', 1, 'cucumber,ogórek,ogorek', 'produce,vegetable', 'any'),
  ('Eggplant', '', 1.0, 5.9, 0.2, 200, 'seed_script', 1, 'eggplant,aubergine,baklazan,баклажан,oberżyna,oberzyna', 'produce,vegetable', 'any'),
  ('Garlic', '', 6.4, 33.1, 0.5, 10, 'seed_script', 1, 'garlic,czosnek', 'produce,vegetable', 'any'),
  ('Green beans', '', 1.8, 7.0, 0.1, 160, 'seed_script', 1, 'green beans,french beans,fasolka szparagowa', 'produce,vegetable', 'any'),
  ('Green peas', '', 5.4, 14.5, 0.4, 160, 'seed_script', 1, 'green peas,peas,groch', 'produce,vegetable', 'any'),
  ('Kale', '', 4.3, 8.8, 0.9, 120, 'seed_script', 1, 'kale,jarmuż,jarmuz', 'produce,vegetable', 'any'),
  ('Leek', '', 1.5, 14.2, 0.3, 120, 'seed_script', 1, 'leek,por', 'produce,vegetable', 'any'),
  ('Lettuce', '', 1.4, 2.9, 0.2, 80, 'seed_script', 1, 'lettuce,sałata,salata', 'produce,vegetable', 'any'),
  ('Mushrooms', '', 3.1, 3.3, 0.3, 120, 'seed_script', 1, 'mushrooms,pieczarki', 'produce,vegetable', 'any'),
  ('Onion', '', 1.1, 9.3, 0.1, 80, 'seed_script', 1, 'onion,cebula', 'produce,vegetable', 'any'),
  ('Potato', '', 2.0, 17.0, 0.1, 250, 'seed_script', 1, 'potato,ziemniak,ziemniaki', 'produce,vegetable', 'any'),
  ('Pumpkin', '', 1.0, 6.5, 0.1, 200, 'seed_script', 1, 'pumpkin,dynia', 'produce,vegetable', 'any'),
  ('Radish', '', 0.7, 3.4, 0.1, 80, 'seed_script', 1, 'radish,rzodkiewka', 'produce,vegetable', 'any'),
  ('Spinach', '', 2.9, 3.6, 0.4, 80, 'seed_script', 1, 'spinach,szpinak', 'produce,vegetable', 'any'),
  ('Tomato', '', 0.9, 3.9, 0.2, 120, 'seed_script', 1, 'tomato,pomidor,pomidory', 'produce,vegetable', 'any'),
  ('Zucchini', '', 1.2, 3.1, 0.3, 180, 'seed_script', 1, 'zucchini,courgette,cukinia', 'produce,vegetable', 'any')
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

