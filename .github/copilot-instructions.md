# Copilot Instructions — Mont

## Notifications (REQUIRED)

Use `notify-send` whenever you finish a task or need human intervention:

```bash
notify-send "Mont" "Task complete: <brief summary>"
notify-send "Mont" "Action needed: <what the human must do>"
```

Never leave a long-running task without notifying at the end.

---

## Project overview

**Mont** is a personal fitness app:
- **Backend**: Rust/Axum, SQLite via sqlx — `backend/`
- **Frontend**: Flutter/Android — `flutter/`
- **Watch**: Amazfit Cheetah Pro, ZeppOS 3, Huami 2021 BLE protocol

The Flutter app syncs workout and health data from the watch over BLE and uploads to the backend.

---

## Starting the backend

```bash
cd backend
just hot-reload        # cargo watch with auto-reload (recommended)
# or: cargo run -- -vv
```

Listens on **port 8080**. Uses `/tmp/mont/mont.sqlite` as the runtime DB (not `backend/mont.sqlite`).

---

## Running the Flutter app on the Android device

Device ID: **CPH2465**

```bash
#!/usr/bin/env bash
LOG=/home/mat/projects/mont/flutter-android.log
> "$LOG"
echo "Logs → $LOG"
adb reverse tcp:8080 tcp:8080
flutter run -d CPH2465 2>&1 | tee "$LOG"
```

Or build + install without keeping the process:
```bash
cd flutter
flutter build apk --debug
adb install -r build/app/outputs/flutter-apk/app-debug.apk
adb reverse tcp:8080 tcp:8080
adb logcat -d flutter:I *:S    # check logs after testing on device
```

The app has a **Health** tab with two sync buttons:
- Bluetooth icon — normal sync from last stored date
- ↺ icon — force re-sync from 15 days ago (bypasses stored timestamp)

Check the DB after a sync:
```bash
sqlite3 /tmp/mont/mont.sqlite \
  "SELECT date, avg_hr, min_hr, max_hr, steps FROM daily_health ORDER BY date DESC LIMIT 10;"
```

---

## Running tests

**Backend (Rust):**
```bash
cd backend
cargo test
# or watch mode:
just test-watch
```

**Flutter:**
```bash
cd flutter
flutter test
```

**Lint/check:**
```bash
cd backend && cargo clippy   # or: just clippy-watch
cd flutter && flutter analyze
```

Always run tests before committing. Fix any failures caused by your changes; ignore pre-existing unrelated failures.

---

## BLE / Watch protocol

### Data fetch types (endpoint 0x004B)

| Type | Name | Description |
|------|------|-------------|
| `0x01` | ACTIVITY | Per-minute 8-byte samples. HR in b3 is sentinel `1` during exercise. |
| `0x02` | MANUAL_HEART_RATE | Manual spot-check HR |
| `0x05` | SPORTS_SUMMARIES | Workout summaries |
| `0x06` | SPORTS_DETAILS | GPS + per-sample HR for one workout |
| `0x3a` | RESTING_HEART_RATE | **Daily resting/min HR** — one 6-byte record per day |
| `0x3d` | MAX_HEART_RATE | **Daily max HR including exercise** — one 6-byte record per day |
| `0x12`/`0x13` | STRESS_MANUAL/AUTO | Stress / likely source of HRV data |

### 8-byte ACTIVITY sample layout (type 0x01)
```
b0: kind        (64=OUTDOOR_RUNNING, 115=NOT_WORN, 118=CHARGING, 120=SLEEP)
b1: intensity
b2: steps
b3: heartRate   (1=no-reading sentinel; valid range: >= 40 && < 255)
b4: unknown1
b5: sleep
b6: deepSleep
b7: remSleep
```
Each sample = 1 minute. `firstSampleTime` comes from the fetch response timestamp.

### 6-byte daily HR record layout (types 0x3a and 0x3d)
```
bytes 0-3: unix timestamp seconds, little-endian uint32
byte 4:    UTC offset in quarter-hours (signed int8)
byte 5:    heart rate BPM (uint8)
```
One record per day. All data starts after a 2-byte chunk header (skip first 2 bytes of assembled chunks).

**Source**: Confirmed from Gadgetbridge `FetchHeartRateMaxOperation.java` and `FetchHeartRateRestingOperation.java`.

### Watch quirks
- Watch sends **no response at all** (timeout, not count=0) when it has no new data for a given type and date.
- `deleteFromWatch: true` (ACK byte `0x01`) resets the watch's transfer pointer.
- `deleteFromWatch: false` (ACK byte `0x09`) marks as transferred but keeps data on watch.
- `type 0x3a` gives the correct daily **resting/min** HR (not derivable from 0x01 passive monitoring).
- `type 0x3d` gives the correct daily **max** HR including exercise peaks (e.g. 137 BPM during a run). The 0x01 passive data only shows ~60 BPM max.

### BLE characteristics
- Service: `0000fee0-0000-1000-8000-00805f9b34fb`
- Chunked write char: `00000005-0000-3512-2118-0009af100700`
- Chunked read char: `00000004-0000-3512-2118-0009af100700`
- Auth char: `00000009-0000-3512-2118-0009af100700`

---

## Key source files

| File | Purpose |
|------|---------|
| `flutter/lib/src/ble/watch_sync_service.dart` | Main BLE sync orchestrator. `_fetchHealthData()` fetches 0x3a/0x3d/0x13 first, then 0x01 activity loop. |
| `flutter/lib/src/ble/health_parser.dart` | `parseActivitySamples()` for 0x01; `parseDailyHrSamples()` for 0x3a/0x3d; `parseStressSamples()` for 0x13 |
| `flutter/lib/src/ble/activity_list.dart` | Protocol builders, `HuamiDataType` constants |
| `flutter/lib/src/ble/settings.dart` | SharedPreferences helpers incl. `clearLastHealthSyncTime()` |
| `flutter/lib/src/views/health_screen.dart` | Health UI; ↺ force-sync button calls `syncHealthOnlyFrom(now - 15 days)` |
| `backend/src/routes/health.rs` | Health API: `import_health_ble`, `last_health_date`, `list_daily_health` |
| `flutter/lib/src/api.dart` | Dart API client incl. `importHealthBle()`, `lastHealthDate()` |

---

## Gadgetbridge reference

GB source for Huami health parsing:
`https://github.com/Freeyourgadget/Gadgetbridge/tree/master/app/src/main/java/nodomain/freeyourgadget/gadgetbridge/service/devices/huami/operations/fetch/`

Key classes: `FetchHeartRateMaxOperation`, `FetchHeartRateRestingOperation`, `FetchStressAutoOperation`, `AbstractRepeatingFetchOperation`, and `HuamiFetchDataType`.

---

## Current status (as of 2026-03-17)

HR data types 0x3a and 0x3d are implemented but **not yet verified working end-to-end**. The test run was cut off before the 0x3a/0x3d log lines appeared. After the next sync, check for:

```
[BLE] Resting HR: 15 day(s): {2026-03-15: 46, ...}
[BLE] Max HR: 15 day(s): {2026-03-15: 137, ...}
[BLE] Stress: 15 day(s): {2026-03-15: 42, ...}
```

If both HR types show `0 day(s)`, the watch is not responding to these types — investigate the request format or whether a different `since` date is needed.

Stress data (type `0x13`) is now fetched and stored as a daily average score (0-100). There is **no dedicated HRV RMSSD type** in the BLE protocol — HRV RMSSD only comes from FIT file imports.
