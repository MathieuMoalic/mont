-- Deduplicate runs imported twice through different sources, and fix the
-- started_at convention of BLE details imports.
--
-- The BLE details importer (until v0.15.5) recorded the watch's TIMESTAMP
-- TLV as the workout start; that TLV is actually the moment the details
-- record was written — the workout's END. Every BLE-imported run therefore
-- started "duration_s" too late, and runs that had previously come in via
-- the Gadgetbridge zip import (source_file '*.bin', correct start time)
-- existed twice: same distance, same duration, different times.
--
-- 1) Delete BLE runs that duplicate an existing run with identical
--    distance and duration (the .bin twin keeps the correct start time).
-- 2) Shift every remaining BLE-imported run back by its duration so its
--    started_at is the true workout start.

DELETE FROM runs
WHERE source_file LIKE 'ble-%'
  AND EXISTS (
    SELECT 1 FROM runs other
    WHERE other.id != runs.id
      AND other.distance_m = runs.distance_m
      AND other.duration_s = runs.duration_s
      AND other.id < runs.id
  );

UPDATE runs
SET started_at = strftime('%Y-%m-%dT%H:%M:%SZ',
                           strftime('%s', started_at) - duration_s, 'unixepoch')
WHERE source_file LIKE 'ble-%';
