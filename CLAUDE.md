# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Mont is a personal fitness tracking app (Rust backend + Flutter frontend) for logging gym workouts, body weight, and runs with Gadgetbridge integration.

## Common Commands

### Backend (Rust/Axum)

```bash
cd backend
cargo run -- -vv              # Run with debug logging
cargo clippy -- -D warnings   # Lint (strict)
cargo test                    # Run all tests
cargo test <test_name>        # Run single test
```

### Flutter

```bash
cd flutter
flutter pub get               # Install dependencies
flutter run -d chrome         # Run web
flutter run -d <device-id>    # Run Android (use `adb reverse tcp:8080 tcp:8080` first)
flutter analyze               # Lint
flutter test                  # Run tests
```

### Version Management

```bash
just bump patch   # Bump version, commit, and tag (major/minor/patch)
```

## Architecture

### Backend (`backend/`)

- **Framework**: Axum 0.8 with Tower middleware stack
- **Database**: SQLite via sqlx with compile-time checked queries
- **Auth**: Single-password JWT authentication (Argon2 hash)
- **Key modules**:
  - `routes/` - API handlers (auth, exercises, workouts, weight, runs, health)
  - `auth_middleware.rs` - JWT validation middleware
  - `embedded_web.rs` - Serves Flutter web build from embedded assets
  - `config.rs` - CLI args and env vars (all prefixed `MONT_*`)

**Linting**: Strict clippy settings in `lib.rs` - all warnings denied plus pedantic/nursery/cargo lints.

**Tests**: Integration tests in `backend/tests/` with shared utilities in `tests/common/`.

### Flutter (`flutter/`)

- **Platforms**: Web and Android
- **UI**: Material Design 3
- **Key structure**:
  - `lib/src/views/` - Screen widgets
  - `lib/src/api.dart` - HTTP client and API calls
  - `lib/src/platform/` - Platform-specific implementations (kv_store, gpx_picker)

**Platform abstractions**: Uses conditional imports for web vs native differences (see `platform_io.dart`/`platform_stub.dart` pattern).

### Data Flow

1. Flutter calls REST API endpoints
2. Backend validates JWT, applies rate limiting
3. sqlx queries SQLite database
4. Production: Backend serves embedded Flutter web build as single binary

## Environment Variables

All backend config uses `MONT_*` prefix:
- `MONT_PASSWORD_HASH` - Argon2 password hash (required)
- `MONT_JWT_SECRET` - JWT signing secret (auto-generated if not set)
- `MONT_BIND` - Server address (default: `0.0.0.0:8080`)
- `MONT_DB` - Database path (default: `mont.sqlite`)
- `MONT_GADGETBRIDGE_ZIP` - Path to Gadgetbridge export for run imports

## Deployment

- **NixOS**: `flake.nix` provides a systemd service module
- **Release**: Git tags `v*` trigger GitHub Actions to build Android APK + backend binary with embedded web UI
