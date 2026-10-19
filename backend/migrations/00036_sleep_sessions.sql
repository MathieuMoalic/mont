-- Sleep sessions (fetch type 0x48, 594-byte records): the watch's own sleep
-- segmentation with per-session stages, totals, avg HR and its score.
CREATE TABLE sleep_sessions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    ts INTEGER NOT NULL UNIQUE,
    midnight_ts INTEGER NOT NULL,
    sleep_start_min INTEGER NOT NULL,
    sleep_end_min INTEGER NOT NULL,
    avg_hr INTEGER NOT NULL DEFAULT 0,
    score INTEGER NOT NULL DEFAULT 0,
    deep_min INTEGER NOT NULL DEFAULT 0,
    light_min INTEGER NOT NULL DEFAULT 0,
    rem_min INTEGER NOT NULL DEFAULT 0,
    wake_min INTEGER NOT NULL DEFAULT 0
);

CREATE INDEX idx_sleep_sessions_midnight ON sleep_sessions (midnight_ts);

-- Stage intervals in minutes relative to the midnight before `midnight_ts`;
-- stage: 0=awake, 1=light, 2=deep, 3=REM (normalized from the watch's
-- 7=awake, 4=light, 5=deep, 8=REM).
CREATE TABLE sleep_stages (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    session_ts INTEGER NOT NULL,
    start_min INTEGER NOT NULL,
    end_min INTEGER NOT NULL,
    stage INTEGER NOT NULL
);

CREATE INDEX idx_sleep_stages_session ON sleep_stages (session_ts);
