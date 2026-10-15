-- BLE watch sync: raw per-minute activity samples (idempotent re-fetches),
-- HRV readings, daily resting/max HR marks, and per-type sync state.
CREATE TABLE activity_samples (
    ts INTEGER PRIMARY KEY,
    kind INTEGER NOT NULL,
    steps INTEGER NOT NULL,
    hr INTEGER NOT NULL,
    source TEXT NOT NULL DEFAULT 'ble'
);

CREATE TABLE hrv_samples (
    ts INTEGER PRIMARY KEY,
    value INTEGER NOT NULL,
    source TEXT NOT NULL DEFAULT 'ble'
);

CREATE TABLE daily_hr_marks (
    date TEXT PRIMARY KEY,
    resting_hr INTEGER,
    max_hr INTEGER,
    updated_at TEXT NOT NULL
);

CREATE TABLE watch_sync_state (
    data_type INTEGER PRIMARY KEY,
    last_sync_ts INTEGER NOT NULL,
    last_ack INTEGER NOT NULL,
    updated_at TEXT NOT NULL
);
