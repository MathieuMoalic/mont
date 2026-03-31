-- Recreate exercises table to change UNIQUE constraint from name-only to (name, equipment)
-- SQLite doesn't support ALTER COLUMN, so we must recreate the table
-- NOTE: FK constraints are disabled at connection level during migrations

-- Clean up orphaned workout_sets first
DELETE FROM workout_sets WHERE exercise_id NOT IN (SELECT id FROM exercises);

-- Create new table without UNIQUE on name column
CREATE TABLE exercises_new (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    name         TEXT NOT NULL,
    notes        TEXT,
    muscle_group TEXT,
    equipment    TEXT
);

-- Copy all data preserving IDs
INSERT INTO exercises_new (id, name, notes, muscle_group, equipment)
SELECT id, name, notes, muscle_group, equipment FROM exercises;

-- Drop old table and rename new one
DROP TABLE exercises;
ALTER TABLE exercises_new RENAME TO exercises;

-- Add unique constraint on (name, equipment) when equipment is NOT NULL
CREATE UNIQUE INDEX idx_exercise_name_equipment ON exercises(name, equipment) WHERE equipment IS NOT NULL;

-- Add unique constraint on name when equipment IS NULL
CREATE UNIQUE INDEX idx_exercise_name_no_equipment ON exercises(name) WHERE equipment IS NULL;
