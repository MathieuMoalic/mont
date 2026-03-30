-- Drop the unique constraint on name alone
-- SQLite doesn't support DROP CONSTRAINT, so we need to recreate the table
-- We need to temporarily disable foreign keys to recreate the table

PRAGMA foreign_keys = OFF;

CREATE TABLE exercises_new (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    name         TEXT NOT NULL,
    notes        TEXT,
    muscle_group TEXT,
    equipment    TEXT
);

INSERT INTO exercises_new (id, name, notes, muscle_group, equipment)
SELECT id, name, notes, muscle_group, equipment FROM exercises;

DROP TABLE exercises;

ALTER TABLE exercises_new RENAME TO exercises;

-- Add unique constraint on (name, equipment) but only when equipment is NOT NULL
-- This allows exercises with the same name but different equipment
-- When equipment is NULL, names can be duplicated (for exercises without specified equipment)
CREATE UNIQUE INDEX idx_exercise_name_equipment ON exercises(name, equipment) WHERE equipment IS NOT NULL;

-- Also keep a unique constraint on name alone when equipment IS NULL (optional - for cleaner data)
CREATE UNIQUE INDEX idx_exercise_name_no_equipment ON exercises(name) WHERE equipment IS NULL;

PRAGMA foreign_keys = ON;
