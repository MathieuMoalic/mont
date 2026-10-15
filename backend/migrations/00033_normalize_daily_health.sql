-- The BLE daily refresh stored AVG() results (REAL) into the INTEGER columns
-- of daily_health; normalize the type so sqlx integer decoding keeps working.
UPDATE daily_health SET avg_hr = CAST(avg_hr AS INTEGER) WHERE typeof(avg_hr) = 'real';
UPDATE daily_health SET steps = CAST(steps AS INTEGER) WHERE typeof(steps) = 'real';
UPDATE daily_health SET min_hr = CAST(min_hr AS INTEGER) WHERE typeof(min_hr) = 'real';
UPDATE daily_health SET max_hr = CAST(max_hr AS INTEGER) WHERE typeof(max_hr) = 'real';
