CREATE TABLE daily_health (
    date      TEXT NOT NULL UNIQUE,  -- YYYY-MM-DD (UTC)
    avg_hr    INTEGER,
    min_hr    INTEGER,
    max_hr    INTEGER,
    hrv_rmssd REAL,
    steps     INTEGER
);
