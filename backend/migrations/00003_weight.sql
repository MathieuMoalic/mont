CREATE TABLE weight_entries (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    measured_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    weight_kg   REAL NOT NULL
);
