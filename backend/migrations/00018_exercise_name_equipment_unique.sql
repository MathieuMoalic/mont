-- Change unique constraint from (name) to (name, equipment)
-- This allows e.g. "Chest Press (Barbell)" and "Chest Press (Dumbbell)"

CREATE TABLE exercises_new (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    name         TEXT NOT NULL,
    notes        TEXT,
    muscle_group TEXT,
    equipment    TEXT,
    UNIQUE(name, equipment)
);

INSERT INTO exercises_new (id, name, notes, muscle_group, equipment)
SELECT id, name, notes, muscle_group, equipment FROM exercises;

DROP TABLE exercises;

ALTER TABLE exercises_new RENAME TO exercises;
