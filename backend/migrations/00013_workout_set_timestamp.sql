-- Add logged_at timestamp to workout_sets to track when each set was performed
ALTER TABLE workout_sets ADD COLUMN logged_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
