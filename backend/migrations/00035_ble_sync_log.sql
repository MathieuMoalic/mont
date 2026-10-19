-- Sync history for the app's Settings tab: one row per meaningful fetch
-- result (import, or failure) from each BLE session.
CREATE TABLE ble_sync_log (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    ts TEXT NOT NULL,
    source TEXT NOT NULL DEFAULT 'sync',
    kind TEXT NOT NULL,
    status TEXT NOT NULL,
    stored INTEGER NOT NULL DEFAULT 0,
    detail TEXT NOT NULL DEFAULT ''
);

CREATE INDEX idx_ble_sync_log_ts ON ble_sync_log (ts DESC);
