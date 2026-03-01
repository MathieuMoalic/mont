ALTER TABLE runs ADD COLUMN source_file TEXT;
CREATE UNIQUE INDEX IF NOT EXISTS runs_source_file ON runs (source_file) WHERE source_file IS NOT NULL;
