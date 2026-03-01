-- Workout templates: saved workout structures to reuse
CREATE TABLE workout_templates (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    name       TEXT    NOT NULL,
    notes      TEXT,
    created_at TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);

-- Individual exercise slots within a template
CREATE TABLE template_sets (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    template_id INTEGER NOT NULL REFERENCES workout_templates(id) ON DELETE CASCADE,
    exercise_id INTEGER NOT NULL REFERENCES exercises(id) ON DELETE CASCADE,
    set_number  INTEGER NOT NULL,
    target_reps INTEGER NOT NULL DEFAULT 8,
    target_weight_kg REAL NOT NULL DEFAULT 0
);
