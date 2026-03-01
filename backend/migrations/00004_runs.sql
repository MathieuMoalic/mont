CREATE TABLE runs (
    id               INTEGER PRIMARY KEY AUTOINCREMENT,
    started_at       TEXT NOT NULL,
    duration_s       INTEGER NOT NULL,
    distance_m       REAL NOT NULL,
    elevation_gain_m REAL,
    avg_hr           INTEGER,
    max_hr           INTEGER,
    notes            TEXT,
    route_json       TEXT NOT NULL DEFAULT '[]'
);
