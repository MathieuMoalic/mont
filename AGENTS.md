## Project overview

Mont is a personal fitness tracking app for logging gym workouts, body weight,
and runs.

The repository has two main parts:

- `backend/` — Rust backend using Axum and SQLite via `sqlx`
- `flutter/` — Flutter frontend for web and Android

The backend exposes a REST API. The Flutter app calls the backend API. In
production, the backend can serve the embedded Flutter web build.

## Development environment

Prefer entering the Nix development shell before running project commands:

```bash
nix develop
```

The dev shell is expected to provide Rust, Cargo, Clippy, Rustfmt, Flutter,
Dart, Android tools, `just`, `cargo-watch`, `watchexec`, SQLite, and `sqlx-cli`.

If not using Nix, make sure equivalent tooling is available on `PATH`.

## Repository commands

Use `just` recipes where available.

### Backend

Run the backend watcher:

```bash
just backend
```

Equivalent command:

```bash
cd backend && cargo watch -q -c -w src -w Cargo.toml -x 'run -- -v'
```

Run backend checks:

```bash
cd backend && cargo clippy -- -D warnings
cd backend && cargo test
```

Run a single backend test:

```bash
cd backend && cargo test <test_name>
```

### Flutter web

Run the Flutter web server:

```bash
just web
```

Equivalent command:

```bash
cd flutter && flutter run -d web-server --web-hostname 127.0.0.1 --web-port 5173
```

Run Flutter checks:

```bash
cd flutter && flutter analyze
cd flutter && flutter test
```

### Flutter Android

Run the configured Android target:

```bash
just android
```

Equivalent command:

```bash
adb reverse tcp:8080 tcp:8080
cd flutter && flutter run --flavor dev -d CPH2465
```

Before changing Android device commands, inspect connected devices:

```bash
flutter devices
adb devices
```

## Agent-managed dev servers

Long-running commands must not be run directly in the agent’s main shell unless
the task explicitly requires an interactive foreground process.

When the agent needs runtime logs, hot reload, hot restart, or repeated server
restarts, use named `tmux` sessions and log files under `.agent/logs/`.

Create the log directory first:

```bash
mkdir -p .agent/logs
```

### Backend session

Start or restart the backend in an agent-owned session:

```bash
tmux kill-session -t dev-backend 2>/dev/null || true
: > .agent/logs/backend.log
tmux new-session -d -s dev-backend -c "$PWD/backend" \
  "cargo watch -q -c -w src -w Cargo.toml -x 'run -- -v'"
tmux pipe-pane -o -t dev-backend "cat >> '$PWD/.agent/logs/backend.log'"
```

Read backend logs:

```bash
tail -n 200 .agent/logs/backend.log
```

Follow backend logs:

```bash
tail -f .agent/logs/backend.log
```

Stop the backend session:

```bash
tmux kill-session -t dev-backend 2>/dev/null || true
```

### Flutter web session

Start or restart Flutter web in an agent-owned session:

```bash
tmux kill-session -t dev-web 2>/dev/null || true
: > .agent/logs/web.log
tmux new-session -d -s dev-web -c "$PWD/flutter" \
  "flutter run -d web-server --web-hostname 127.0.0.1 --web-port 5173"
tmux pipe-pane -o -t dev-web "cat >> '$PWD/.agent/logs/web.log'"
```

Read web logs:

```bash
tail -n 200 .agent/logs/web.log
```

Send Flutter hot reload:

```bash
tmux send-keys -t dev-web r
```

Send Flutter hot restart:

```bash
tmux send-keys -t dev-web R
```

Stop the web session:

```bash
tmux kill-session -t dev-web 2>/dev/null || true
```

### Flutter Android session

Start or restart Flutter Android in an agent-owned session:

```bash
tmux kill-session -t dev-android 2>/dev/null || true
: > .agent/logs/android.log
tmux new-session -d -s dev-android -c "$PWD/flutter" \
  "adb reverse tcp:8080 tcp:8080 && flutter run --flavor dev -d CPH2465"
tmux pipe-pane -o -t dev-android "cat >> '$PWD/.agent/logs/android.log'"
```

Read Android logs:

```bash
tail -n 200 .agent/logs/android.log
```

Send Flutter hot reload:

```bash
tmux send-keys -t dev-android r
```

Send Flutter hot restart:

```bash
tmux send-keys -t dev-android R
```

Stop the Android session:

```bash
tmux kill-session -t dev-android 2>/dev/null || true
```

### Session status and cleanup

List agent-owned sessions:

```bash
tmux list-sessions 2>/dev/null | grep '^dev-' || true
```

Stop all agent-owned dev sessions:

```bash
tmux kill-session -t dev-backend 2>/dev/null || true
tmux kill-session -t dev-web 2>/dev/null || true
tmux kill-session -t dev-android 2>/dev/null || true
```

Only manage `tmux` sessions whose names start with `dev-`. Do not kill unrelated
user processes.

## Runtime workflow for coding agents

When modifying backend code:

1. Run or restart the backend session.
2. Reproduce the relevant behavior.
3. Inspect `.agent/logs/backend.log`.
4. Run targeted tests.
5. Run `cargo clippy -- -D warnings` before reporting completion when practical.

When modifying Flutter code:

1. Run or restart the relevant Flutter target.
2. Prefer hot reload with `r` after small UI changes.
3. Use hot restart with `R` after state, initialization, dependency injection,
   or platform-channel changes.
4. Inspect the relevant log file under `.agent/logs/`.
5. Run `flutter analyze` and relevant tests before reporting completion when
   practical.

Do not run both `just web` and `just android` casually from the same checkout
unless the task requires both targets. Prefer one Flutter target at a time for
agent workflows.

## Environment and secrets

Backend configuration uses `MONT_*` environment variables.

Common backend variables include:

- `MONT_PASSWORD_HASH`
- `MONT_JWT_SECRET`
- `MONT_BIND`
- `MONT_DB`
- `MONT_GADGETBRIDGE_ZIP`

Use `backend/.env.example` as the starting point for local backend
configuration.

Do not commit real secrets, API keys, JWT secrets, password hashes, local
database files, logs, or device-specific paths.

Do not print secrets into logs or final responses.

## Database notes

The backend uses SQLite.

Before modifying database-related code, inspect:

- `backend/src/`
- `backend/tests/`
- any migrations or SQL query files present in `backend/`

After changing SQL, database schema, or query logic, run backend tests.

If `sqlx` compile-time query metadata is involved, prefer using the project’s
established workflow rather than inventing a new one.

## Code quality expectations

### Rust

- Preserve strict Clippy cleanliness.
- Do not silence Clippy warnings unless there is a clear reason.
- Prefer explicit error handling over panics in application code.
- Keep route handlers thin where possible.
- Put reusable backend logic outside route handlers.
- Add or update tests for behavior changes.

Before finishing backend work, run:

```bash
cd backend && cargo fmt
cd backend && cargo clippy -- -D warnings
cd backend && cargo test
```

### Flutter

- Keep platform-specific behavior behind the existing platform abstraction
  pattern.
- Avoid duplicating API logic across views.
- Keep HTTP/API changes centralized in the existing API layer.
- Prefer small widgets and clear state ownership.
- Add or update tests for behavior changes where practical.

Before finishing Flutter work, run:

```bash
cd flutter && dart format .
cd flutter && flutter analyze
cd flutter && flutter test
```

## Versioning and releases

The `just bump TYPE` recipe changes versions, commits, and creates a Git tag.

Do not run this command unless the user explicitly asks for a release/version
bump:

```bash
just bump patch
just bump minor
just bump major
```

When asked to bump a version, inspect the resulting diff before committing or
tagging.

## Git workflow

Do not create commits, tags, branches, or pull requests unless explicitly asked.

Before making broad changes, inspect the current status:

```bash
git status --short
```

Do not overwrite user changes. If existing uncommitted changes are present,
preserve them and avoid destructive commands.

Avoid commands such as:

```bash
git reset --hard
git clean -fd
```

unless the user explicitly authorizes destructive cleanup.

## Final response expectations

When reporting completion:

- Summarize what changed.
- Mention which checks were run.
- Mention any checks that were not run.
- Mention relevant runtime logs inspected.
- Include known limitations or follow-up work.

Do not claim that a runtime path was verified unless the relevant server or app
was actually run and logs or behavior were inspected.

## Agent completion notifications

When the agent has finished a task and is waiting for the user's next command,
question, or approval, it should send a desktop notification with `notify-send`
when available.

Use a short, non-sensitive message, for example:

```bash
notify-send "Mont agent" "Task complete — waiting for your next command."
```

If the agent is blocked and needs user input before continuing, use:

```bash
notify-send "Mont agent" "Waiting for your answer."
```
