CREATE TABLE issue_reports (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    message TEXT NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    client_version TEXT,
    server_version TEXT,
    platform TEXT,
    base_url TEXT,
    route TEXT,
    extra_json TEXT
);

CREATE INDEX idx_issue_reports_created_at ON issue_reports(created_at);

