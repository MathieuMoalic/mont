-- Add logged_at timestamp to workout_sets to track when each set was performed
-- SQLite doesn't allow non-constant defaults in ALTER TABLE, so we add with a constant
-- default then update existing rows
ALTER TABLE workout_sets ADD COLUMN logged_at TEXT NOT NULL DEFAULT '1970-01-01T00:00:00Z';
UPDATE workout_sets SET logged_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE logged_at = '1970-01-01T00:00:00Z';
