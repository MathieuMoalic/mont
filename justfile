set shell := ["bash", "-uc"]

# Bump version (major, minor, or patch)
bump TYPE:
    #!/usr/bin/env bash
    set -euo pipefail

    current=$(grep '^version = ' backend/Cargo.toml | head -1 | sed 's/version = "\(.*\)"/\1/')
    IFS='.' read -r major minor patch <<< "$current"

    case "{{TYPE}}" in
        major) major=$((major + 1)); minor=0; patch=0 ;;
        minor) minor=$((minor + 1)); patch=0 ;;
        patch) patch=$((patch + 1)) ;;
        *) echo "Error: TYPE must be major, minor, or patch"; exit 1 ;;
    esac

    new_version="$major.$minor.$patch"
    echo "Bumping version: $current → $new_version"

    sed -i "s/^version = \"$current\"/version = \"$new_version\"/" backend/Cargo.toml
    sed -i "s/^version: $current$/version: $new_version/" flutter/pubspec.yaml
    (cd backend && cargo check --quiet)

    git add backend/Cargo.toml backend/Cargo.lock flutter/pubspec.yaml
    git diff --cached
    git commit -m "Bump version to $new_version"
    git tag -a "v$new_version" -m "Release v$new_version"
    echo "✓ Version bumped to $new_version and tagged"

backend:
    cd backend && cargo watch -q -c -w src -w Cargo.toml -x 'run -- -v'

android:
  adb reverse tcp:8080 tcp:8080
  cd flutter && flutter run --flavor dev -d CPH2465

web:
  cd flutter && flutter run -d web-server --web-hostname 127.0.0.1 --web-port 5173

cp-db:
  rm -rf /tmp/mont 
  mkdir /tmp/mont
  scp homeserver:/var/lib/mont/mont.sqlite /tmp/mont/mont.sqlite


# Agent-managed commands

[private]
agent-init:
    mkdir -p .agent/logs

agent-backend: agent-init
    #!/usr/bin/env bash
    set -euo pipefail

    session="dev-backend"
    log="$PWD/.agent/logs/backend.log"

    tmux kill-session -t "$session" 2>/dev/null || true
    : > "$log"

    tmux new-session -d -s "$session" -c "$PWD/backend" \
      "cargo watch -q -c -w src -w Cargo.toml -x 'run -- -v'"

    tmux pipe-pane -o -t "$session" "cat >> '$log'"

agent-android: agent-init
    #!/usr/bin/env bash
    set -euo pipefail

    session="dev-android"
    log="$PWD/.agent/logs/android.log"

    tmux kill-session -t "$session" 2>/dev/null || true
    : > "$log"

    tmux new-session -d -s "$session" -c "$PWD/flutter" \
      "adb reverse tcp:8080 tcp:8080 && flutter run --flavor dev -d CPH2465"

    tmux pipe-pane -o -t "$session" "cat >> '$log'"

agent-web: agent-init
    #!/usr/bin/env bash
    set -euo pipefail

    session="dev-web"
    log="$PWD/.agent/logs/web.log"

    tmux kill-session -t "$session" 2>/dev/null || true
    : > "$log"

    tmux new-session -d -s "$session" -c "$PWD/flutter" \
      "flutter run -d web-server --web-hostname 127.0.0.1 --web-port 5173"

    tmux pipe-pane -o -t "$session" "cat >> '$log'"

agent-stop name:
    tmux kill-session -t "dev-{{name}}" 2>/dev/null || true

agent-stop-all:
    tmux kill-session -t dev-backend 2>/dev/null || true
    tmux kill-session -t dev-android 2>/dev/null || true
    tmux kill-session -t dev-web 2>/dev/null || true

agent-restart name:
    just agent-stop {{name}}
    just agent-{{name}}

agent-logs name="backend":
    tail -n "${N:-200}" ".agent/logs/{{name}}.log"

agent-follow name="backend":
    tail -f ".agent/logs/{{name}}.log"

agent-attach name:
    tmux attach -t "dev-{{name}}"

agent-status:
    tmux list-sessions 2>/dev/null | grep '^dev-' || true

agent-send name key:
    tmux send-keys -t "dev-{{name}}" "{{key}}"
