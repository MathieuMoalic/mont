CREATE TABLE body_pictures (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    picture_date DATE NOT NULL UNIQUE,
    picture_data BLOB NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX idx_body_pictures_date ON body_pictures(picture_date);
