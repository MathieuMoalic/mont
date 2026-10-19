-- Sleep stages per activity sample and per-minute stress samples.
ALTER TABLE activity_samples ADD COLUMN sleep INTEGER;
ALTER TABLE activity_samples ADD COLUMN deep_sleep INTEGER;
ALTER TABLE activity_samples ADD COLUMN rem_sleep INTEGER;

CREATE TABLE IF NOT EXISTS stress_samples (
    ts INTEGER PRIMARY KEY,
    stress INTEGER NOT NULL
);
