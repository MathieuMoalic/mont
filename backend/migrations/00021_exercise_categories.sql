CREATE TABLE exercise_categories (
    kind TEXT NOT NULL CHECK (kind IN ('muscle_group', 'equipment')),
    name TEXT NOT NULL,
    color_hex TEXT,
    sort_order INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (kind, name)
);
