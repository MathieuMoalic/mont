# Mont

> **Vibe coded with [Claude Sonnet 4.6](https://www.anthropic.com/claude).**

**Mont** means *move* in Breton. It's a personal fitness tracking app for logging gym workouts, body weight, and runs.

## Stack

- **Backend** — Rust / Axum / SQLite (via sqlx)
- **Frontend** — Flutter (web + Android)

## Features

- **Workouts** — track exercises, sets, reps, and weight
- **Weight** — log body weight over time with a trend chart
- **Runs** — import from a [Gadgetbridge](https://gadgetbridge.org/) zip export; view route map, HR, pace, and elevation charts; weekly km and fitness trend graphs

## Getting started

### Backend

```bash
cd backend
cp .env.example .env   # set MONT_PASSWORD_HASH, MONT_JWT_SECRET, etc.
cargo run -- -vv
```

The server listens on `0.0.0.0:8080` by default.

Key CLI options (also available as `MONT_*` env vars):

| Flag | Env var | Default |
|---|---|---|
| `--bind` | `MONT_BIND` | `0.0.0.0:8080` |
| `--db` | `MONT_DB` | `mont.sqlite` |
| `--gadgetbridge-zip` | `MONT_GADGETBRIDGE_ZIP` | *(none)* |

### Flutter

```bash
cd flutter
flutter pub get

# Web
flutter run -d chrome

# Android (with backend forwarded over adb)
adb reverse tcp:8080 tcp:8080
flutter run -d <device-id>
```

## Development

```bash
# Backend checks
cd backend && cargo clippy -- -D warnings && cargo test

# Flutter checks
cd flutter && flutter analyze && flutter test
```

A pre-commit hook runs all three automatically.

## Importing runs from Gadgetbridge

Point `MONT_GADGETBRIDGE_ZIP` at your daily Gadgetbridge export zip (e.g. `/home/you/dl/Gadgetbridge.zip`). Then hit the **↻** sync button in the Runs tab. Re-syncing is idempotent — already-imported runs are skipped.
