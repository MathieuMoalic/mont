-- Add CHECK constraints to ensure non-negative values for numeric fields
-- SQLite requires table recreation to add constraints

-- Recreate weight_entries with CHECK constraint
CREATE TABLE weight_entries_new (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    measured_at TEXT    NOT NULL DEFAULT (datetime('now')),
    weight_kg   REAL    NOT NULL CHECK (weight_kg > 0)
);

INSERT INTO weight_entries_new (id, measured_at, weight_kg)
SELECT id, measured_at, weight_kg FROM weight_entries WHERE weight_kg > 0;

DROP TABLE weight_entries;
ALTER TABLE weight_entries_new RENAME TO weight_entries;

-- Recreate workout_sets with CHECK constraints
CREATE TABLE workout_sets_new (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    workout_id  INTEGER NOT NULL REFERENCES workouts(id) ON DELETE CASCADE,
    exercise_id INTEGER NOT NULL REFERENCES exercises(id),
    set_number  INTEGER NOT NULL CHECK (set_number > 0),
    reps        INTEGER NOT NULL CHECK (reps >= 0),
    weight_kg   REAL    NOT NULL CHECK (weight_kg >= 0),
    logged_at   TEXT    NOT NULL DEFAULT (datetime('now'))
);

INSERT INTO workout_sets_new (id, workout_id, exercise_id, set_number, reps, weight_kg, logged_at)
SELECT id, workout_id, exercise_id, set_number, reps, weight_kg, logged_at 
FROM workout_sets 
WHERE set_number > 0 AND reps >= 0 AND weight_kg >= 0;

DROP TABLE workout_sets;
ALTER TABLE workout_sets_new RENAME TO workout_sets;

-- Add indexes back
CREATE INDEX idx_workout_sets_workout_id ON workout_sets(workout_id);
CREATE INDEX idx_workout_sets_exercise_id ON workout_sets(exercise_id);
